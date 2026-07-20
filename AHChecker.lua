addon.name      = 'AHChecker';
addon.author    = 'Zeroized';
addon.version   = '1.0.1';
addon.desc      = 'Checks HorizonXI Auction House prices using the official PSXI API.';
addon.link      = 'https://www.psxi.gg/developers';

require('common');

local chat  = require('chat');
local socket = require('socket');
local ssl   = require('ssl');
local json  = require('json');

local API_HOST = 'www.psxi.gg';
local API_PATH = '/api/v1/market/horizonxi';
local CACHE_LIFETIME_SECONDS = 60 * 60;
local REQUEST_TIMEOUT_SECONDS = 45;
local CACHE_FILE = (addon.path or '.\\') .. 'market-cache.json';

local state = {
    payload = nil,
    items_by_name = nil,
    cached_at = nil,
    refresh = nil,
    pending_lookup = nil,
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
    return index;
end

local function decode_payload(body)
    local ok, payload = pcall(json.decode, body);
    if (not ok) then
        return nil, 'Could not decode PSXI market data: ' .. tostring(payload);
    end

    local index, index_error = build_index(payload);
    if (index == nil) then
        return nil, index_error;
    end
    return payload, index;
end

local function read_cache()
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

    local payload, index_or_error = decode_payload(body);
    if (payload == nil) then
        return nil;
    end

    return {
        payload = payload,
        index = index_or_error,
        cached_at = cached_at,
        body = body,
    };
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
    local age = os.time() - cached_at;
    return age >= 0 and age < CACHE_LIFETIME_SECONDS;
end

local function has_fresh_market_data()
    if (state.payload ~= nil and cache_is_fresh(state.cached_at)) then
        return true;
    end

    local disk_cache = read_cache();
    if (disk_cache ~= nil and cache_is_fresh(disk_cache.cached_at)) then
        install_snapshot(disk_cache.payload, disk_cache.index, disk_cache.cached_at);
        return true;
    end
    return false;
end

local show_item;

local function finish_refresh(body, reason)
    local refresh = state.refresh;
    state.refresh = nil;

    if (refresh.socket ~= nil) then
        refresh.socket:close();
    end

    if (body ~= nil) then
        local payload, index_or_error = decode_payload(body);
        if (payload ~= nil) then
            local fetched_at = os.time();
            install_snapshot(payload, index_or_error, fetched_at);
            if (not write_cache(body, fetched_at)) then
                failure('Market data loaded, but the local cache could not be written.');
            end
        else
            reason = index_or_error;
        end
    end

    if (state.payload == nil) then
        if (refresh.disk_cache ~= nil) then
            install_snapshot(refresh.disk_cache.payload, refresh.disk_cache.index, refresh.disk_cache.cached_at);
            info('PSXI refresh failed (' .. tostring(reason) .. '); using an older cached snapshot.');
        else
            failure('PSXI refresh failed (' .. tostring(reason) .. ').');
        end
    end

    local lookup = state.pending_lookup;
    state.pending_lookup = nil;
    if (lookup ~= nil and state.payload ~= nil) then
        local item = state.items_by_name[normalize_name(lookup.item_name)];
        if (item == nil) then
            failure('Item not found: ' .. lookup.item_name .. '. Use the complete in-game item name.');
        else
            show_item(item, lookup.listing_type);
        end
    elseif (lookup ~= nil) then
        failure('No PSXI market data is available. Please try again later.');
    end
end

local function begin_market_refresh()
    if (state.refresh ~= nil) then
        info('PSXI refresh is already in progress; the latest lookup will be shown when it finishes.');
        return;
    end

    local tcp, create_error = socket.tcp();
    if (tcp == nil) then
        failure('PSXI refresh failed (' .. tostring(create_error) .. ').');
        state.pending_lookup = nil;
        return;
    end

    tcp:settimeout(0);
    state.refresh = {
        socket = tcp,
        stage = 'connecting',
        started_at = os.time(),
        disk_cache = read_cache(),
        chunks = {},
    };

    local connected, connect_error = tcp:connect(API_HOST, 443);
    if (not connected and connect_error ~= 'timeout' and connect_error ~= 'Operation already in progress') then
        finish_refresh(nil, connect_error);
        return;
    end

    info('Refreshing the hourly PSXI market snapshot in the background...');
end

local function is_waiting_for_io(reason)
    return reason == 'timeout' or reason == 'wantread' or reason == 'wantwrite';
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
        local peer = refresh.socket:getpeername();
        if (peer == nil) then
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
            refresh.stage = 'receiving';
        elseif (not is_waiting_for_io(send_error)) then
            finish_refresh(nil, send_error);
        end
        return;
    end

    local chunk, receive_error, partial = refresh.socket:receive(8192);
    if (chunk ~= nil and chunk ~= '') then
        table.insert(refresh.chunks, chunk);
    end
    if (partial ~= nil and partial ~= '') then
        table.insert(refresh.chunks, partial);
    end

    if (receive_error == 'closed') then
        local response = table.concat(refresh.chunks);
        local header, body = response:match('^(.-)\r\n\r\n(.*)$');
        local code = header and header:match('^HTTP/%d+%.%d+%s+(%d%d%d)');
        if (tonumber(code) == 200 and body ~= nil and body ~= '') then
            finish_refresh(body);
        else
            finish_refresh(nil, code and ('HTTP ' .. code) or 'invalid HTTP response');
        end
    elseif (not is_waiting_for_io(receive_error)) then
        finish_refresh(nil, receive_error);
    end
end

local function show_help()
    info('Usage: /ahc "Item Name" [single|stack]');
    info('Examples: /ahc "Hauberk"  |  /ahc "Eye Drops" stack');
    info('The listing type defaults to single. Data is cached for one hour.');
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
    local window_days = state.payload.meta and state.payload.meta.statsWindowDays or 7;
    info(string.format('%sd: median %s | avg %s | range %s-%s | sales %s',
        tostring(window_days),
        format_gil(stats.median),
        format_gil(stats.avg),
        format_gil(stats.min),
        format_gil(stats.max),
        format_number(stats.volume)));

    local generated_at = state.payload.meta and state.payload.meta.generatedAt or nil;
    if (generated_at ~= nil) then
        info('Snapshot: ' .. format_date(generated_at));
    end
end

ashita.events.register('command', 'ahchecker_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/ahc')) then
        return;
    end

    e.blocked = true;

    if (#args < 2 or args[2]:lower() == 'help') then
        show_help();
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
        state.pending_lookup = {
            item_name = item_name,
            listing_type = listing_type,
        };
        begin_market_refresh();
        return;
    end

    local item = state.items_by_name[normalize_name(item_name)];
    if (item == nil) then
        failure('Item not found: ' .. item_name .. '. Use the complete in-game item name.');
        return;
    end

    show_item(item, listing_type);
end);

ashita.events.register('d3d_present', 'ahchecker_refresh_cb', function ()
    pump_market_refresh();
end);
