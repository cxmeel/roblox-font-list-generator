--!strict
local function trim(input: string): string
    return input:gsub("^%s*(.-)%s*$", "%1")
end

local function fileNamify(input: string): string
    local sanitized = input:gsub("[^%w_]", "_"):gsub("__+", "_"):gsub("^_", ""):gsub("_$", "")
    return trim(sanitized)
end

return {
    trim = trim,
    fileNamify = fileNamify,
}
