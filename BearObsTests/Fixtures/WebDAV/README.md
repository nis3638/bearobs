# BearObs Controlled WebDAV Fixture

This synthetic M0-06 fixture contains no real Vault content, credentials, or private service URLs.

`contract.json` defines the immutable initial resource snapshot and the golden `Depth: 1`
PROPFIND response. `ControlledWebDAVFixture` provides deterministic GET, conditional PUT, 412,
HTTP error, timeout, and interrupted-download behavior through a session-local `URLProtocol`.

The fixture proves the HTTP contract only. It does not replace real TLS, authentication challenge,
redirect, or vendor compatibility testing.
