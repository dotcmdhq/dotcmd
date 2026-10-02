# TODO

- Implement persistent completion caching. Normal invocations atomically cache the result of loading `.cmd.lua`: either completion metadata or failure. `--complete` reuses an existing cached result. If none exists, it loads `.cmd.lua` once and caches the outcome. Successful results provide project completions; failed results provide built-ins only.
- remove all type annotation comments and make them from scratch
