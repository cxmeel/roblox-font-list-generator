--!strict
--[[
    $ lune -- diff <oldFilePath> <newFilePath>

    Generates a basic diff file between two `FontList.lua` files.

    The diff file is written to `build/FontList.diff` and shows
    only the additions and deletions between the two files; it
    does not display modifications to existing fonts at this
    time.
--]]
local process = require("@lune/process")
local luau = require("@lune/luau")
local fs = require("@lune/fs")

local logger = require("utils/logger")
local colors = require("utils/colors")
local ufs = require("utils/ufs")

local Font = require("struct/font")

local OLD_FILE_PATH = ufs.normalizePath(`{process.cwd}/{process.args[1]}`)
local NEW_FILE_PATH = ufs.normalizePath(`{process.cwd}/{process.args[2]}`)

local function createRecursiveTable(): { [any]: any }
    return setmetatable({}, {
        __index = function()
            return createRecursiveTable()
        end
    }) :: any
end

local function validateProcessArguments()
    if typeof(OLD_FILE_PATH) ~= "string" or typeof(NEW_FILE_PATH) ~= "string" then
        logger.error("Usage: lune -- diff <oldFilePath> <newFilePath>")
        process.exit(1)
    end

    if not fs.isFile(OLD_FILE_PATH) then
        logger.error(`File "{OLD_FILE_PATH}" does not exist`)
        process.exit(1)
    end

    if not fs.isFile(NEW_FILE_PATH) then
        logger.error(`File "{NEW_FILE_PATH}" does not exist`)
        process.exit(1)
    end

    local oldFileMetadata = fs.metadata(OLD_FILE_PATH)
    local newFileMetadata = fs.metadata(NEW_FILE_PATH)

    if oldFileMetadata.modifiedAt > newFileMetadata.modifiedAt then
        logger.warn("The old file is newer than the new file")
    end

    return true
end

local function generateDiffArrays()
    local oldFileContent = fs.readFile(OLD_FILE_PATH)
    local newFileContent = fs.readFile(NEW_FILE_PATH)

    local oldFileBytecode = luau.compile(oldFileContent)
    local newFileBytecode = luau.compile(newFileContent)

    -- local oldFontList = require(OLD_FILE_PATH) :: { Font.IFont }
    -- local newFontList = require(NEW_FILE_PATH) :: { Font.IFont }
    local oldFontList = luau.load(oldFileBytecode, {
        environment = createRecursiveTable(),
    })() :: { Font.IFont }

    local newFontList = luau.load(newFileBytecode, {
        environment = createRecursiveTable(),
    })() :: { Font.IFont }

    local additions = {} :: { Font.IFont }
    local deletions = {} :: { Font.IFont }

    for _, oldFont in oldFontList do
        local found = false

        for _, newFont in newFontList do
            if oldFont.Name == newFont.Name then
                found = true
                break
            end
        end

        if not found then
            table.insert(deletions, oldFont)
        end
    end

    for _, newFont in newFontList do
        local found = false

        for _, oldFont in oldFontList do
            if oldFont.Name == newFont.Name then
                found = true
                break
            end
        end

        if not found then
            table.insert(additions, newFont)
        end
    end

    table.sort(additions, function(a, b)
        return a.Name < b.Name
    end)

    table.sort(deletions, function(a, b)
        return a.Name < b.Name
    end)

    return {
        additions = additions,
        deletions = deletions,
    }
end

local function main()
    validateProcessArguments()

    local diffs = generateDiffArrays()
    local diffLines = {}

    for _, deletion in diffs.deletions do
        table.insert(diffLines, `- {deletion.Name}`)
    end

    for _, addition in diffs.additions do
        table.insert(diffLines, `+ {addition.Name}`)
    end

    if #diffLines == 0 then
        logger.log("No changes detected")
        process.exit(0)
    end

    logger.info(`Changes detected: {colors.yellow(#diffLines)}`)
    logger.info(`Additions: {colors.green(#diffs.additions)}`)
    logger.info(`Deletions: {colors.red(#diffs.deletions)}`)

    print("Writing diff file to", colors.blue("build/FontList.diff"))
    ufs.writeFile("build/FontList.diff", table.concat(diffLines, "\n"))

    print(colors.green.bold.inverse(" SUCCESS "), "Diff file generated successfully! 🎉")
end

main()
