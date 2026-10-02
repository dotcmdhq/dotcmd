local function encode(value)
    return (value:gsub("[^%w._~-]", function(byte) return ("%%%02X"):format(byte:byte()) end))
end

local function request(url, budget, consumer, headers)
    assert(budget.remaining > 0, "download budget exhausted")
    return http {
        url = url, headers = headers,
        to = function()
            local consume = consumer()
            return function(chunk)
                if chunk == nil then return consume() end
                budget.remaining = budget.remaining - #chunk
                assert(budget.remaining >= 0, "download budget exhausted")
                consume(chunk)
            end
        end,
    }.body
end

local function github(path, budget)
    local body = request("https://api.github.com/repos/" .. path, budget, function()
        local chunks = {}
        return function(chunk)
            if chunk == nil then return table.concat(chunks) end
            chunks[#chunks + 1] = chunk
        end
    end, { Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" })
    return json.decode(body)
end

local function download_hash(url, budget, size)
    assert(not size or size <= budget.remaining, "download budget exhausted")
    return request(url, budget, sha256)
end

local function write_pair(result)
    io.stdout:write("url: ", result.url, "\nsha256: ", result.sha256, "\n")
end

local function write_result(format, result)
    if format == "json" then
        io.stdout:write(json.encode(result), "\n")
    else
        write_pair(result)
    end
end

local repo_argument = {
    "repository",
    description = "GitHub owner/repo",
    parse = function(value)
        local owner, repo = value:match("^([^/]+)/([^/]+)$")
        if owner then return encode(owner) .. "/" .. encode(repo) end
        return nil, "expected owner/repo"
    end
}

return {
    description = [[Resolve download URLs and SHA-256 hashes

Outputs url/sha256 pairs as text or JSON.
Stops on the first error without printing partial results.]],
    opts = {
        format = { type = { "text", "json" }, default = "text", description = "Output format" },
        max_download_mb = { type = "number", default = 64, description = "Shared budget for metadata and file bodies, in MB (1 MB = 1,000,000 bytes)" },
    },
    tasks = {
        url = {
            description = [[Hash a file at an HTTPS URL

Streams the file without saving it. Keeps the supplied URL when following redirects.
JSON output is a single object.]],
            args = { { "url", description = "HTTPS download URL" } },
            run = function(options, url)
                local budget = { remaining = options.max_download_mb * 1000000 }
                local result = { url = url, sha256 = download_hash(url, budget) }
                write_result(options.format, result)
            end
        },
        github_file = {
            description = [[Resolve a GitHub repository file

Resolves the selected ref to a commit and hashes the file without saving it.
Outputs a commit-pinned raw-file URL and SHA-256. JSON output is a single object.]],
            opts = { ref = { description = "Branch, tag, or commit (default: repository default branch)" } },
            args = { repo_argument, { "path", description = "File path relative to the repository root" } },
            run = function(options, repo, path)
                local budget = { remaining = options.max_download_mb * 1000000 }
                local ref = options.ref or github(repo, budget).default_branch
                local commit = github(repo .. "/commits/" .. encode(ref), budget).sha
                local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. commit .. "/" .. path:gsub("[^/]+", encode)
                local result = { url = url, sha256 = download_hash(url, budget) }
                write_result(options.format, result)
            end,
        },
        github_release = {
            description = [[Resolve all assets in a GitHub release

Uses the release's download URLs and published SHA-256 digests.
Assets without a SHA-256 digest are streamed and hashed without saving them.
JSON output is always an array.]],
            opts = { tag = { default = "latest", description = "Release tag or latest" } },
            args = { repo_argument },
            run = function(options, repo)
                local budget = { remaining = options.max_download_mb * 1000000 }
                local endpoint = repo .. "/releases/"
                if options.tag == "latest" then endpoint = endpoint .. "latest"
                else endpoint = endpoint .. "tags/" .. encode(options.tag) end
                local release = github(endpoint, budget)
                local results = json.decode("[]")
                for _, asset in ipairs(release.assets) do
                    local hash = asset.digest and asset.digest:match("^sha256:(.+)$")
                    if not hash then hash = download_hash(asset.browser_download_url, budget, asset.size) end
                    results[#results + 1] = { url = asset.browser_download_url, sha256 = hash:lower() }
                end
                if options.format == "json" then
                    io.stdout:write(json.encode(results), "\n")
                else
                    for index, result in ipairs(results) do
                        if index > 1 then io.stdout:write("\n") end
                        write_pair(result)
                    end
                end
            end,
        },
    },
}
