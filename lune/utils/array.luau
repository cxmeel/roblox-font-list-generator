local function map<T, U>(array: { T }, mapper: (value: T, index: number, array: { T }) -> U?): { U }
	local mapped = {}

	for index, value in ipairs(array) do
		local mappedValue = mapper(value, index, array)

		if mappedValue ~= nil then
			table.insert(mapped, mappedValue)
		end
	end

	return mapped
end

return {
	map = map,
}
