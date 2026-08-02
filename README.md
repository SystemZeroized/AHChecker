# AHChecker

AHChecker is an Ashita v4 addon for HorizonXI. It looks up current Auction House information using PSXI's official, read-only market API.

For the requested single-item or stack listing, AHChecker displays current stock, the most recent sale and its timestamp, and PSXI's rolling market statistics: median, average, minimum, maximum, and sales volume. The output also includes the snapshot timestamp.

## Install

### Recommended

1. Open the [latest release](https://github.com/SystemZeroized/AHChecker/releases/latest).
2. Download the `AHChecker-vX.Y.Z.zip` file from the release assets (for example, `AHChecker-v1.1.0.zip`).
3. Extract the ZIP into `<HORIZONXI_GAME>\addons`.

The installed addon should be located at:

```text
<HORIZONXI_GAME>\addons\AHChecker\AHChecker.lua
```

Then load it in game with:

```text
/addon load AHChecker
```

`<HORIZONXI_GAME>` means your HorizonXI `Game` directory.

### Manual installation

Create an `AHChecker` folder under `<HORIZONXI_GAME>\addons`, then copy `AHChecker.lua` from this repository into it.

## Usage

```text
/ahc "Hauberk"
/ahc "Brigandine +1"
/ahc "Eye Drops" stack
/ahc "Eye Drops" single
/ahc refresh
/ahc help
```

Omitting `single` or `stack` defaults to `single`. Item-name matching is case-insensitive, but the complete item name is required. Quotes are recommended and required for names containing spaces. If a name is not found, AHChecker suggests close matches from the snapshot.

`/ahc refresh` forces a new snapshot immediately, ignoring the cache.

The first lookup downloads PSXI's HorizonXI market snapshot. AHChecker caches successful data for one hour in `market-cache.json`, beside the addon. Further lookups use that cache. If a refresh fails, AHChecker falls back to any older cached snapshot available and reports how old it is.

## Data source and fair use

AHChecker uses `GET https://www.psxi.gg/api/v1/market/horizonxi`. The API is public, read-only, and requires no API key. PSXI documents the snapshot as hourly refreshed, and the API advertises a rate limit of 25 requests per minute and 100 per day per IP. AHChecker performs lookups only on demand, never refreshes a successful snapshot more than once per hour, and waits 60 seconds before retrying after a failed refresh. It does not scrape web pages.

### Endpoint deprecation

As of August 2026, PSXI returns `Deprecation: true` and `Sunset: Sun, 01 Nov 2026` on this endpoint. It works today and returns the schema AHChecker expects, but it is scheduled to be withdrawn. AHChecker prints a one-time notice in game when it sees those headers. Migration to the successor endpoint is tracked as future work; see [PSXI's developer documentation](https://www.psxi.gg/developers) for the current API.

## Privacy

AHChecker does not collect character, account, chat, or gameplay data. It sends only an unauthenticated GET request for PSXI's complete HorizonXI market snapshot; item searches happen locally and are not sent to PSXI. As with any web request, PSXI can see the requesting IP address.

## License

AHChecker is released under the [MIT License](LICENSE).
