--!strict
--[[
	The shape of a Roblox font family descriptor: the JSON behind a
	`rbxasset://fonts/families/*.json` file, or a cloud font asset of the
	same form.
]]

export type FontStyle = "normal" | "italic"

export type FontFace = {
	name: string,
	weight: number,
	style: FontStyle,
	assetId: string,
}

export type FontFamily = {
	name: string,
	faces: { FontFace },
}

local REGULAR_WEIGHT = 400

--- Picks the face to represent a family: upright at regular weight, falling
--- back to whichever face the family lists first.
local function regularFace(family: FontFamily): FontFace
	for _, face in family.faces do
		if face.style == "normal" and face.weight == REGULAR_WEIGHT then
			return face
		end
	end

	return family.faces[1]
end

return {
	regularFace = regularFace,
}
