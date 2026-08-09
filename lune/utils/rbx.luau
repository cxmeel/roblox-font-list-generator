--!strict
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local ufs = require("./ufs")

local resolvedInstallationPath: string? = nil

local function studioInstallationPath(): string?
	if resolvedInstallationPath then
		return resolvedInstallationPath
	end

	local studioAppPath = ufs.normalizePath(roblox.studioApplicationPath()):split("/")

	table.remove(studioAppPath, #studioAppPath)
	table.remove(studioAppPath, #studioAppPath)

	local versionsPath = table.concat(studioAppPath, "/")

	for _, dir in fs.readDir(versionsPath) do
		local candidatePath = ufs.normalizePath(`{versionsPath}/{dir}`)
		local candidateExe = ufs.normalizePath(`{candidatePath}/RobloxStudioBeta.exe`)

		if fs.isFile(candidateExe) then
			resolvedInstallationPath = candidatePath
			return resolvedInstallationPath
		end
	end

	return nil
end

local function studioContentPath(): string?
	local installationPath = studioInstallationPath()
	local contentPath = ufs.normalizePath(`{installationPath}/content`)

	if not installationPath or not fs.isDir(contentPath) then
		return nil
	end

	return contentPath
end

local function studioApplicationPath(): string?
	local installationPath = studioInstallationPath()
	local applicationPath = ufs.normalizePath(`{installationPath}/RobloxStudioBeta.exe`)

	if not installationPath or not fs.isFile(applicationPath) then
		return nil
	end

	return applicationPath
end

return {
	studioInstallationPath = studioInstallationPath,
	studioContentPath = studioContentPath,
	studioPluginPath = roblox.studioPluginPath,
	studioApplicationPath = studioApplicationPath,
}
