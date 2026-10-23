# DNZ documentation

The user documentation of DNZ, a self-hosted
authoritative DNS server and forwarder, as a [Mintlify](https://mintlify.com) site: guides, the
`dnz` command line and the HTTP API.

## Preview

```bash
npx mint dev            # http://localhost:3000
npx mint validate       # what the deploy build checks
npx mint broken-links
```

## Layout

- `docs.json`: navigation, theme and links
- `index.mdx`, `get-started/`, `deploy/`, `dashboard/`, `dns/`, `proxy/`, `integrations/`,
  `admin/`: the Guide tab
- `cli/`: the CLI tab
- `api/`: the API tab
- `changelog.mdx`: the Changelog tab, written by the DNZ release workflow after every release; don't
  edit it here
- `monitoring/`, `bench/`, `swarm/`: files the pages tell readers to download (Prometheus + Grafana,
  the benchmark harness, the dnz-proxy Swarm stack). The DNZ release workflow copies them here after
  every release; don't edit them here

Pages are MDX. Link between pages with root-relative paths without the extension
(`/dns/forwarding`), and keep `<` and `{` inside backticks in prose.

When a feature changes in DNZ, update its page here.
