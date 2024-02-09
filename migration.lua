for _, entry in pairs(global.selector) do
	entry.old_inputs = {}
	entry.old_outputs = {}
	entry.cb.parameters = nil
	update_single_entry(entry)
end
