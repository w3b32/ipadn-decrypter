# Vendored Decrypter

`Core/` and `Runner/` are the working Decrypter 3.4.1 implementation copied from
source commit `bbb5e9c326811e8f5d06ce2106865acfb37c7eb8`, with original byte
hashes in PROVENANCE.json. Integration adaptations are recorded separately: payload
preparation canonicalizes aliased parent paths and its tests cover that entry point. The preparation core compiles into iPadn; the runner
has its own app target and remains a zipped, unsigned template until the user
prepares, signs and installs it.

The original test fixtures are retained. Python fixture paths are adapted
to this layout; decryption/signature algorithms are unchanged. `test_integration_packaging.py`
checks the actual runner packager and standard/lite conversion tools.

Portable checks:

```sh
python3 -m unittest discover -s Tests -v
swift run -c release PayloadLayoutTests
```

The Swift package is for host regression tests, not the iPhone app build. It uses
the same pinned Swift Crypto dependency as the original Linux checks; Apple
targets continue to use CryptoKit. See ../../DECRYPTER_INTEGRATION.md for scope,
build steps and validation limits.
