addon.name      = 'AHChecker';
addon.author    = 'Zeroized';
addon.version   = '1.1.0';
addon.desc      = 'Checks HorizonXI Auction House prices using the official PSXI API.';
addon.link      = 'https://www.psxi.gg/developers';

require('common');

local chat   = require('chat');
local socket = require('socket');
-- Ashita ships LuaSec under the socket namespace (addons/libs/socket/ssl.lua).
-- A plain require('ssl') will not resolve on the default package.path.
local ssl    = require('socket.ssl');
local json   = require('json');

local API_HOST = 'www.psxi.gg';
local API_PATH = '/api/v1/market/horizonxi';
local CACHE_LIFETIME_SECONDS = 60 * 60;
local REQUEST_TIMEOUT_SECONDS = 90;
local FAILURE_COOLDOWN_SECONDS = 60;
-- Bytes pulled off the socket per frame. The snapshot is ~2.2MB, so a single
-- small read per frame would take minutes of wall clock to drain.
local READ_BUDGET_PER_FRAME = 256 * 1024;
local READ_CHUNK = 16 * 1024;
local CACHE_FILE = (addon.path or '.\\') .. 'market-cache.json';

local state = {
    payload = nil,
    items_by_name = nil,
    cached_at = nil,
    refresh = nil,
    pending_lookup = nil,
    retry_after = 0,
    deprecation_warned = false,
};

local function info(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

local function failure(message)
    print(chat.header(addon.name):append(chat.error(message)));
end

local function trim(value)
    return (value:gsub('^%s+', ''):gsub('%s+$', ''));
end

local function normalize_name(value)
    return trim(value):lower():gsub('%s+', ' ');
end

local function format_number(value)
    if (value == nil) then
        return '-';
    end

    local number = math.floor(tonumber(value) or 0);
    local sign = number < 0 and '-' or '';
    local digits = tostring(math.abs(number));
    local formatted = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '');
    return sign .. formatted;
end

local function format_gil(value)
    if (value == nil) then
        return '-';
    end
    return format_number(value) .. ' gil';
end

local function format_date(value)
    if (value == nil or value == '') then
        return '-';
    end

    local year, month, day, hour, minute = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)');
    if (year == nil) then
        return value;
    end
    return string.format('%s-%s-%s %s:%s UTC', year, month, day, hour, minute);
end

--------------------------------------------------------------------------------
-- Snapshot handling
--------------------------------------------------------------------------------

local function build_index(payload)
    if (type(payload) ~= 'table' or type(payload.data) ~= 'table') then
        return nil, 'PSXI returned an unexpected response.';
    end

    local index = {};
    for _, item in ipairs(payload.data) do
        if (type(item) == 'table' and type(item.itemName) == 'string') then
            index[normalize_name(item.itemName)] = item;
        end
    end

    if (next(index) == nil) then
        return nil, 'PSXI returned an empty market snapshot.';
    end
    return index;
end

local function decode_payload(body)
    local ok, payload = pcall(json.decode, body);
    if (not ok) then
        return nil, 'could not decode PSXI market data: ' .. tostring(payload);
    end

    local index, index_error = build_index(payload);
    if (index == nil) then
        return nil, index_error;
    end
    return payload, index;
end

-- Returns the raw cache body without decoding it. Decoding is ~2.2MB of work,
-- so it is deferred until we actually intend to use the snapshot.
local function read_cache_body()
    local file = io.open(CACHE_FILE, 'rb');
    if (file == nil) then
        return nil;
    end

    local first_line = file:read('*l');
    local body = file:read('*a');
    file:close();

    local cached_at = tonumber(first_line);
    if (cached_at == nil or body == nil or body == '') then
        return nil;
    end
    return body, cached_at;
end

local function write_cache(body, cached_at)
    local file = io.open(CACHE_FILE, 'wb');
    if (file == nil) then
        return false;
    end

    file:write(tostring(cached_at), '\n', body);
    file:close();
    return true;
end

local function install_snapshot(payload, index, cached_at)
    state.payload = payload;
    state.items_by_name = index;
    state.cached_at = cached_at;
end

local function cache_is_fresh(cached_at)
    if (cached_at == nil) then
        return false;
    end
    local age = os.time() - cached_at;
    return age >= 0 and age < CACHE_LIFETIME_SECONDS;
end

local function load_disk_snapshot()
    local body, cached_at = read_cache_body();
    if (body == nil) then
        return false;
    end

    local payload, index_or_error = decode_payload(body);
    if (payload == nil) then
        return false;
    end

    install_snapshot(payload, index_or_error, cached_at);
    return true;
end

local function has_fresh_market_data()
    if (state.payload ~= nil and cache_is_fresh(state.cached_at)) then
        return true;
    end

    if (state.payload == nil and load_disk_snapshot()) then
        return cache_is_fresh(state.cached_at);
    end
    return false;
end

--------------------------------------------------------------------------------
-- HTTP response parsing
--------------------------------------------------------------------------------

local function parse_headers(block)
    local status_line, rest = block:match('^([^\r\n]*)\r\n(.*)$');
    if (status_line == nil) then
        status_line, rest = block, '';
    end

    local code = tonumber(status_line:match('^HTTP/%d+%.%d+%s+(%d%d%d)'));
    local headers = {};
    for line in rest:gmatch('([^\r\n]+)') do
        local key, value = line:match('^([^:]+):%s*(.-)%s*$');
        if (key ~= nil) then
            headers[key:lower()] = value;
        end
    end
    return code, status_line, headers;
end

-- Consumes as much of refresh.buffer as possible. Returns true once the full
-- body has been read, or nil plus a message on a protocol error.
local function consume_buffer(refresh, connection_closed)
    if (refresh.stage == 'headers') then
        local head, rest = refresh.buffer:match('^(.-)\r\n\r\n(.*)$');
        if (head == nil) then
            if (connection_closed) then
                return nil, 'connection closed before headers arrived';
            end
            return false;
        end

        refresh.buffer = rest;
        refresh.code, refresh.status_line, refresh.headers = parse_headers(head);

        if (refresh.code ~= 200) then
            return nil, 'HTTP ' .. tostring(refresh.status_line or refresh.code);
        end

        local encoding = (refresh.headers['transfer-encoding'] or ''):lower();
        if (encoding:find('chunked', 1, true)) then
            refresh.mode = 'chunked';
            refresh.chunk_remaining = nil;
        else
            local length = tonumber(refresh.headers['content-length']);
            refresh.mode = length and 'length' or 'close';
            refresh.expected = length;
        end
        refresh.stage = 'body';
    end

    if (refresh.mode == 'length' or refresh.mode == 'close') then
        if (#refresh.buffer > 0) then
            table.insert(refresh.body, refresh.buffer);
            refresh.body_length = refresh.body_length + #refresh.buffer;
            refresh.buffer = '';
        end

        if (refresh.mode == 'length') then
            return refresh.body_length >= refresh.expected;
        end
        if (not connection_closed) then
            return false;
        end
        if (refresh.body_length == 0) then
            return nil, 'empty response body';
        end
        return true;
    end

    -- Chunked transfer encoding. PSXI (Vercel) always responds chunked, so this
    -- path is the one that actually runs.
    while (true) do
        if (refresh.chunk_remaining == nil) then
            local size_line, rest = refresh.buffer:match('^([^\r\n]*)\r\n(.*)$');
            if (size_line == nil) then
                if (connection_closed) then
                    return nil, 'connection closed mid-chunk';
                end
                return false;
            end

            local size = tonumber(size_line:match('^(%x+)') or '', 16);
            if (size == nil) then
                return nil, 'malformed chunked response';
            end

            refresh.buffer = rest;
            if (size == 0) then
                return true; -- Terminal chunk; trailers are ignored.
            end
            refresh.chunk_remaining = size;
        end

        -- Need the chunk payload plus its trailing CRLF.
        if (#refresh.buffer < refresh.chunk_remaining + 2) then
            if (connection_closed) then
                return nil, 'connection closed mid-chunk';
            end
            return false;
        end

        table.insert(refresh.body, refresh.buffer:sub(1, refresh.chunk_remaining));
        refresh.body_length = refresh.body_length + refresh.chunk_remaining;
        refresh.buffer = refresh.buffer:sub(refresh.chunk_remaining + 3);
        refresh.chunk_remaining = nil;
    end
end

--------------------------------------------------------------------------------
-- Background refresh
--------------------------------------------------------------------------------

local show_item;

local function close_refresh_socket(refresh)
    if (refresh ~= nil and refresh.socket ~= nil) then
        pcall(function () refresh.socket:close(); end);
        refresh.socket = nil;
    end
end

local function report_deprecation(refresh)
    if (state.deprecation_warned or refresh.headers == nil) then
        return;
    end
    if (refresh.headers['deprecation'] == nil) then
        return;
    end

    state.deprecation_warned = true;
    local sunset = refresh.headers['sunset'];
    if (sunset ~= nil) then
        info('Note: PSXI has marked ' .. API_PATH .. ' deprecated (sunset ' .. sunset .. ').');
    else
        info('Note: PSXI has marked ' .. API_PATH .. ' deprecated.');
    end
end

local function finish_refresh(body, reason)
    local refresh = state.refresh;
    state.refresh = nil;
    if (refresh == nil) then
        return;
    end

    close_refresh_socket(refresh);
    report_deprecation(refresh);

    local succeeded = false;
    if (body ~= nil and body ~= '') then
        local payload, index_or_error = decode_payload(body);
        if (payload ~= nil) then
            local fetched_at = os.time();
            install_snapshot(payload, index_or_error, fetched_at);
            succeeded = true;
            if (not write_cache(body, fetched_at)) then
                failure('Market data loaded, but the local cache could not be written.');
            end
        else
            reason = index_or_error;
        end
    end

    if (not succeeded) then
        state.retry_after = os.time() + FAILURE_COOLDOWN_SECONDS;
        if (state.payload == nil and load_disk_snapshot()) then
            info(string.format('PSXI refresh failed (%s); using a cached snapshot from %s.',
                tostring(reason), os.date('%Y-%m-%d %H:%M', state.cached_at)));
        elseif (state.payload ~= nil) then
            info(string.format('PSXI refresh failed (%s); keeping the snapshot from %s.',
                tostring(reason), os.date('%Y-%m-%d %H:%M', state.cached_at)));
        else
            failure('PSXI refresh failed (' .. tostring(reason) .. ').');
        end
    end

    local lookup = state.pending_lookup;
    state.pending_lookup = nil;
    if (lookup == nil) then
        if (succeeded) then
            info(string.format('PSXI snapshot updated (%s items).', format_number(#state.payload.data)));
        end
        return;
    end

    if (state.payload == nil) then
        failure('No PSXI market data is available. Please try again later.');
        return;
    end

    local item = state.items_by_name[normalize_name(lookup.item_name)];
    if (item == nil) then
        failure('Item not found: ' .. lookup.item_name .. '. Use the complete in-game item name.');
        return;
    end
    show_item(item, lookup.listing_type);
end

local function begin_market_refresh()
    if (state.refresh ~= nil) then
        info('PSXI refresh is already in progress; the latest lookup will be shown when it finishes.');
        return true;
    end

    if (os.time() < state.retry_after) then
        failure(string.format('PSXI refresh is cooling down for another %d second(s).',
            state.retry_after - os.time()));
        state.pending_lookup = nil;
        return false;
    end

    local tcp, create_error = socket.tcp();
    if (tcp == nil) then
        failure('PSXI refresh failed (' .. tostring(create_error) .. ').');
        state.pending_lookup = nil;
        state.retry_after = os.time() + FAILURE_COOLDOWN_SECONDS;
        return false;
    end

    tcp:settimeout(0);
    state.refresh = {
        socket = tcp,
        stage = 'connecting',
        started_at = os.time(),
        buffer = '',
        body = {},
        body_length = 0,
    };

    local connected, connect_error = tcp:connect(API_HOST, 443);
    if (not connected
        and connect_error ~= 'timeout'
        and connect_error ~= 'Operation already in progress'
        and connect_error ~= 'already connected') then
        finish_refresh(nil, connect_error);
        return false;
    end

    info('Refreshing the hourly PSXI market snapshot in the background...');
    return true;
end

local function is_waiting_for_io(reason)
    return reason == nil or reason == 'timeout' or reason == 'wantread' or reason == 'wantwrite';
end

local function pump_market_refresh()
    local refresh = state.refresh;
    if (refresh == nil) then
        return;
    end

    if (os.time() - refresh.started_at >= REQUEST_TIMEOUT_SECONDS) then
        finish_refresh(nil, 'timed out while downloading the snapshot');
        return;
    end

    if (refresh.stage == 'connecting') then
        if (refresh.socket:getpeername() == nil) then
            return;
        end

        local secure, wrap_error = ssl.wrap(refresh.socket, {
            mode = 'client', protocol = 'any', verify = 'none',
            options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1' },
        });
        if (secure == nil) then
            finish_refresh(nil, wrap_error);
            return;
        end

        secure:settimeout(0);
        -- psxi.gg is served from a shared frontend; without SNI the handshake
        -- gets the wrong certificate (or is refused outright).
        if (secure.sni ~= nil) then
            secure:sni(API_HOST);
        end
        refresh.socket = secure;
        refresh.stage = 'handshake';
        return;
    end

    if (refresh.stage == 'handshake') then
        local completed, handshake_error = refresh.socket:dohandshake();
        if (completed) then
            refresh.request = 'GET ' .. API_PATH .. ' HTTP/1.1\r\nHost: ' .. API_HOST
                .. '\r\nUser-Agent: AHChecker/' .. addon.version
                .. '\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n';
            refresh.sent = 0;
            refresh.stage = 'sending';
        elseif (not is_waiting_for_io(handshake_error)) then
            finish_refresh(nil, handshake_error);
        end
        return;
    end

    if (refresh.stage == 'sending') then
        local sent, send_error, partial = refresh.socket:send(refresh.request, refresh.sent + 1);
        refresh.sent = sent or partial or refresh.sent;
        if (refresh.sent >= #refresh.request) then
            refresh.stage = 'headers';
        elseif (not is_waiting_for_io(send_error)) then
            finish_refresh(nil, send_error);
        end
        return;
    end

    -- Receiving. Drain up to a fixed byte budget per frame so a 2MB snapshot
    -- does not take thousands of frames to download.
    local read_this_frame = 0;
    local closed = false;
    local fatal_error = nil;
    local pieces = { refresh.buffer };

    while (read_this_frame < READ_BUDGET_PER_FRAME) do
        local chunk, receive_error, partial = refresh.socket:receive(READ_CHUNK);
        local data = chunk or partial;
        local got = (data ~= nil) and #data or 0;
        if (got > 0) then
            table.insert(pieces, data);
            read_this_frame = read_this_frame + got;
        end

        if (receive_error == 'closed') then
            closed = true;
            break;
        elseif (receive_error ~= nil and not is_waiting_for_io(receive_error)) then
            fatal_error = receive_error;
            break;
        elseif (receive_error ~= nil or got == 0) then
            -- wantread/timeout, or a no-op read: nothing more is buffered now.
            break;
        end
    end

    refresh.buffer = table.concat(pieces);

    local done, parse_error = consume_buffer(refresh, closed);
    if (done == nil) then
        finish_refresh(nil, parse_error);
        return;
    end

    if (done) then
        finish_refresh(table.concat(refresh.body));
    elseif (fatal_error ~= nil) then
        finish_refresh(nil, fatal_error);
    elseif (closed) then
        finish_refresh(nil, 'connection closed before the response was complete');
    end
end

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

local function suggest_items(query)
    if (state.items_by_name == nil) then
        return;
    end

    local needle = normalize_name(query);
    local matches = {};
    for name, item in pairs(state.items_by_name) do
        if (name:find(needle, 1, true)) then
            table.insert(matches, item.itemName);
        end
    end

    if (#matches == 0) then
        return;
    end

    table.sort(matches);
    local shown = {};
    for i = 1, math.min(#matches, 5) do
        shown[i] = matches[i];
    end

    local suffix = (#matches > 5) and string.format(' (+%d more)', #matches - 5) or '';
    info('Did you mean: ' .. table.concat(shown, ', ') .. suffix);
end

local function show_help()
    info('Usage: /ahc "Item Name" [single|stack]');
    info('Examples: /ahc "Hauberk"  |  /ahc "Eye Drops" stack');
    info('/ahc refresh forces a new snapshot. Data is cached for one hour.');
end

show_item = function(item, listing_type)
    if (item.ah == nil) then
        failure(item.itemName .. ' has no Auction House data on HorizonXI.');
        return;
    end

    local stats = item.ah[listing_type];
    if (stats == nil) then
        failure(item.itemName .. ' has no ' .. listing_type .. ' listing data.');
        return;
    end

    local stock = listing_type == 'stack' and item.ah.currentStackStock or item.ah.currentStock;
    info(string.format('%s (%s) - stock: %s', item.itemName, listing_type, format_number(stock)));
    info(string.format('Last: %s on %s', format_gil(stats.lastSale), format_date(stats.lastSaleDate)));

    local meta = state.payload and state.payload.meta or nil;
    local window_days = meta and meta.statsWindowDays or 7;
    info(string.format('%sd: median %s | avg %s | range %s-%s | sales %s',
        tostring(window_days),
        format_gil(stats.median),
        format_gil(stats.avg),
        format_gil(stats.min),
        format_gil(stats.max),
        format_number(stats.volume)));

    if (meta and meta.generatedAt ~= nil) then
        info('Snapshot: ' .. format_date(meta.generatedAt));
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

ashita.events.register('command', 'ahchecker_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/ahc', '/ahchecker')) then
        return;
    end

    e.blocked = true;

    if (#args < 2 or args[2]:lower() == 'help') then
        show_help();
        return;
    end

    if (args[2]:lower() == 'refresh') then
        state.retry_after = 0;
        state.pending_lookup = nil;
        begin_market_refresh();
        return;
    end

    local item_name = args[2];
    local listing_type = (#args >= 3 and args[3]:lower()) or 'single';
    if (listing_type ~= 'single' and listing_type ~= 'stack') then
        failure('Listing type must be single or stack.');
        show_help();
        return;
    end

    if (#args > 3) then
        failure('Item names containing spaces must be enclosed in double quotes.');
        show_help();
        return;
    end

    if (not has_fresh_market_data()) then
        -- A stale snapshot is still better than nothing while the refresh runs.
        local item = state.items_by_name and state.items_by_name[normalize_name(item_name)];
        if (item ~= nil) then
            info(string.format('Showing a snapshot from %s while a refresh runs.',
                os.date('%Y-%m-%d %H:%M', state.cached_at)));
            show_item(item, listing_type);
            state.pending_lookup = nil;
            begin_market_refresh();
            return;
        end

        state.pending_lookup = {
            item_name = item_name,
            listing_type = listing_type,
        };
        if (not begin_market_refresh()) then
            state.pending_lookup = nil;
        end
        return;
    end

    local item = state.items_by_name[normalize_name(item_name)];
    if (item == nil) then
        failure('Item not found: ' .. item_name .. '. Use the complete in-game item name.');
        suggest_items(item_name);
        return;
    end

    show_item(item, listing_type);
end);

ashita.events.register('d3d_present', 'ahchecker_refresh_cb', function ()
    pump_market_refresh();
end);

ashita.events.register('unload', 'ahchecker_unload_cb', function ()
    close_refresh_socket(state.refresh);
    state.refresh = nil;
    state.pending_lookup = nil;
end);
