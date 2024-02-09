local util = require("__core__/lualib/util")

script.on_init(function()
    global.selector = global.selector or {}
    global.rng = game.create_random_generator()
end)

local function get_wire(entity, wire)
    local network = entity.get_circuit_network(wire, defines.circuit_connector_id.combinator_input)
    if network then
        return network.signals
    end
    return nil
end

local function on_built(e)
    if not e.created_entity or e.created_entity.name ~= SCOMBINATOR_NAME then
        return
    end

    local input = e.created_entity
    local output = input.surface.create_entity {
        name = SCOMBINATOR_OUT_NAME,
        position = input.position,
        force = input.force,
        fast_replace = false,
        raise_built = false,
        create_built_effect_smoke = false
    }
    script.register_on_entity_destroyed(input)

    -- connect the combinator to the output of the input
    input.connect_neighbour({
        wire = defines.wire_type.green,
        target_entity = output,
        source_circuit_id = defines.circuit_connector_id.combinator_output
    })
    input.connect_neighbour({
        wire = defines.wire_type.red,
        target_entity = output,
        source_circuit_id = defines.circuit_connector_id.combinator_output
    })

    local entry = {
        input = input,
        output = output,
        cb = output.get_or_create_control_behavior(),

        old_inputs = {},
        old_outputs = {},

        settings = {
            mode = "select-input",

            index = 0,
            index_signal = nil,
            descending = true,

            count_signal = nil,

            update_interval = 1,
            update_unit = 'seconds',
            update_interval_ticks = 60,
            update_interval_now = false,
            random_unique = false
        }
    }

    -- restore from blueprint.
    if e.tags and e.tags[SCOMBINATOR_NAME] then
        entry.settings = util.table.deepcopy(e.tags[SCOMBINATOR_NAME])
        update_selector(entry)
    end

    global.selector[input.unit_number] = entry
end

local function on_removed(e)
    local input = e.entity
    if not input or input.name ~= SCOMBINATOR_NAME then
        return
    end

    local output = global.selector[input.unit_number].output
    global.selector[input.unit_number] = nil

    output.destroy {
        raise_destroy = false
    }
end

local function on_paste(e) 
    local source = e.source
    if not source or source.name ~= SCOMBINATOR_NAME then
        return
    end
    local dest = e.destination
    if not dest or dest.name ~= SCOMBINATOR_NAME then
        return
    end

    local a = global.selector[source.unit_number]
    local b = global.selector[dest.unit_number]
    if not a or not b then
        return
    end

    b.settings = util.table.deepcopy(a.settings)
    b.settings.update_interval_now = true

    update_selector(b)
end

local function get_blueprint(e)
  local player = game.get_player(e.player_index)
  if not player then
    return
  end

  local bp = player.blueprint_to_setup
  if bp and bp.valid_for_read then
    return bp
  end

  bp = player.cursor_stack
  if not bp or not bp.valid_for_read then
    return
  end

  if bp.type == "blueprint-book" then
    local item_inventory = bp.get_inventory(defines.inventory.item_main)
    if item_inventory then
      bp = item_inventory[bp.active_index]
    else
      return
    end
  end

  return bp
end

local function on_blueprint(e)
    local blueprint = get_blueprint(e)
    if not blueprint then
        return
    end

    local entities = blueprint.get_blueprint_entities()
    if not entities then
        return
    end
    for i, entity in pairs(entities) do
        if entity.name ~= SCOMBINATOR_NAME then
            goto continue
        end
        local real_entity = e.surface.find_entity(entity.name, entity.position)
        if not real_entity then
            goto continue
        end
        local entry = global.selector[real_entity.unit_number]
        if entry == nil then
            goto continue
        end
        blueprint.set_blueprint_entity_tag(i, SCOMBINATOR_NAME, util.table.deepcopy(entry.settings))
        ::continue::
    end
end

SORTS = {
    function(a, b) return a.count > b.count end,
    function(a, b) return b.count > a.count end
}

local function update_single_entry(entry)
	-- To skip logic and updates when possible:
	-- select-input, count-inputs, random-input, and stack-size cache old_outputs.
	-- select-input caches old_inputs if the index_signal is nil.
	-- stack-size caches old_inputs, because any non-item input prevents us from comparing inputs to outputs.

	if not entry.output.valid then
		return
	end

	local settings = entry.settings

	-- short circuit for tick
	if settings.mode == 'random-input' then
		if settings.update_interval_now then
			settings.update_interval_now = false
		elseif game.tick % settings.update_interval_ticks ~= 0 then
			return
		end
	end

	-- Only call get_merged_signals once.
	-- The only time we don't use get_merged_signals is when select-input mode has an index signal set in the GUI.
	local signals
	local mode = settings.mode
	if mode ~= 'select-input' or settings.index_signal == nil then
		signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)

		-- Replace most "signals == nil" checks with one here.
		if signals == nil then
			-- Clear state if required, then return.
			if #entry.old_outputs ~= 0 then
				entry.old_inputs = {}
				entry.old_outputs = {}
				entry.cb.parameters = nil
			end
			return
		end
	end

	if mode == 'select-input' then
		local index
		if settings.index_signal == nil then
			-- Short-circuit if merged inputs have not changed.
			local old_inputs = entry.old_inputs
			if #signals == #old_inputs then
				local inputs_unchanged = true
				for i = 1, #signals do
					local sig = signals[i]
					local old = old_inputs[i]
					if sig.count ~= old.count or sig.signal.name ~= old.signal.name then
						-- An input has changed. Update the cache and continue.
						old.count = sig.count
						old.signal.name = sig.signal.name
						old.signal.type = sig.signal.type
						inputs_unchanged = false
					end
				end
				if inputs_unchanged then
					return
				end
			else
				-- Cache doesn't match signals, update it.
				entry.old_inputs = {}
				for i = 1, #signals do
					local sig = signals[i]
					entry.old_inputs[i] = { count = sig.count, signal = sig.signal, index = i }
				end
			end

			-- No index signal was provided, use the index provided in the GUI.
			index = settings.index
		else
			-- An index signal was provided in the GUI. Short-circuit if we don't have any inputs to select from.
			signals = get_wire(entry.input, defines.wire_type.green)
			if signals == nil then
				-- Clear state if required, then return.
				if #entry.old_outputs ~= 0 then
					entry.old_inputs = {}
					entry.old_outputs = {}
					entry.cb.parameters = nil
				end
				return
			end

			-- The index will be the signal's value on the red wire, or 0 if it can't be found.
			index = 0
			local red = get_wire(entry.input, defines.wire_type.red)
			if red ~= nil then
				for _, redSig in pairs(red) do
					if redSig.signal.name == settings.index_signal.name then
						index = redSig.count
						break
					end
				end
			end
		end

		-- If the index is out of range, output nothing.
		if index >= #signals or index < 0 then
			-- Clear state if required, then return.
			if #entry.old_outputs ~= 0 then
				entry.old_inputs = {}
				entry.old_outputs = {}
				entry.cb.parameters = nil
			end
			return
		end

		-- Only sort/search if we need to.
		local sig
		if #signals > 1 then
			-- Optimize for the common cases of searching for the min or max signal
			if index == 0 then
				sig = signals[1]
				count = sig.count
				if settings.descending then
					for _, signal in pairs(signals) do
						if signal.count > count then
							sig = signal
							count = sig.count
						end
					end
				else
					for _, signal in pairs(signals) do
						if signal.count < count then
							sig = signal
							count = sig.count
						end
					end
				end
			else
				-- TODO: cache the sort predicate, and only update it when the setting changes.
				local s
				if settings.descending then s = SORTS[1] else s = SORTS[2] end
				table.sort(signals, s)
				sig = signals[index + 1]
			end
		else
			sig = signals[1]
		end

		-- Short-circuit if the output is unchanged.
		if #entry.old_outputs == 1 then
			local old_signal = entry.old_outputs[1]
			if old_signal.count == sig.count and old_signal.signal.name == sig.signal.name then
				return
			else -- Update the existing output
				old_signal.signal.name = sig.signal.name
				old_signal.signal.type = sig.signal.type
				old_signal.count = sig.count
			end
		else -- Create new output
			entry.old_outputs = {{
				signal = sig.signal,
				count = sig.count,
				index = 1
			}}
		end
	elseif mode == 'count-inputs' then
		if settings.count_signal == nil then
			-- Clear state if required, then return.
			if #entry.old_outputs ~= 0 then
				entry.old_outputs = {}
				entry.cb.parameters = nil
			end
			return
		end

		if #entry.old_outputs == 1 then
			-- Short-circuit if the output is unchanged. Only the count could have changed.
			if entry.old_outputs[1].count == #signals then
				return
			end
			-- Update existing output.
			entry.old_outputs[1].count = #signals
		else
			-- Create new output.
			entry.old_outputs = {{
				signal = settings.count_signal,
				count = #signals,
				index = 1
			}}
		end
	elseif mode == 'random-input' then
		local signal
		-- If we only have one input, select it.
		if #signals == 1 then
			signal = signals[1]
		else
			-- Otherwise, choose a random signal.
			signal = signals[global.rng(#signals)]

			-- if random_unique is set, do we need to re-run the rng?
			if settings.random_unique and #entry.old_outputs == 1 then
				local old = entry.old_outputs[1]
				while signal.signal.name == old.signal.name do
					signal = signals[global.rng(#signals)]
				end
				-- Update the existing output.
				old.signal.name = signal.signal.name
				old.signal.type = signal.signal.type
				old.count = signal.count
				entry.cb.parameters = entry.old_outputs
				return
			end
		end

		-- If we already have the correct number of outputs (1), check if the signal matches.
		if #entry.old_outputs == 1 then
			local old = entry.old_outputs[1]
			-- Short-circuit if we are already outputting the selected signal.
			if signal.count == old.count and signal.signal.name == old.signal.name then
				return
			end
			-- Update the existing output.
			old.signal.name = signal.signal.name
			old.signal.type = signal.signal.type
			old.count = signal.count
		else -- Otherwise, create new output.
			entry.old_outputs = {{
				signal = signal.signal,
				count = signal.count,
				index = 1
			}}
		end
	else -- stack-size
		-- Short-circuit if our inputs are unchanged.
		local old_inputs = entry.old_inputs
		if #signals == #old_inputs then
			local inputs_unchanged = true
			for i = 1, #signals do
				if old_inputs[i] ~= signals[i].signal.name then
					-- Fix the cache.
					old_inputs[i] = signals[i].signal.name
					inputs_unchanged = false
				end
			end

			if inputs_unchanged then
				return
			end
		else
			-- Input cache mismatches; update.
			-- We don't actually need to completely reset the cache. Try either of:
				-- Shrink the extra elements until the cache is the same size or smaller than the input, then update all entries, or
				-- Take over signals: entry.old_inputs = signals

			-- For now, just make it work:
			entry.old_inputs = {}
			for i = 1, #signals do
				entry.old_inputs[i] = signals[i].signal.name
			end
		end

		-- The inputs changed, but this doesn't mean the outputs also have to change.
		-- We could short-circuit at this point if there are no *item* differences between our inputs and our outputs.

		entry.old_outputs = {}
		local i = 1
		for _, signal in pairs(signals) do
			if signal.signal.type == "item" then
				local item = game.item_prototypes[signal.signal.name]
				if item ~= nil then
					entry.old_outputs[i] = {
						signal = signal.signal,
						count = item.stack_size,
						index = i
					}
					i = i + 1
				end
			end
		end
	end

	-- If we reach here, our output needs to be updated.
	entry.cb.parameters = entry.old_outputs
end

---@diagnostic disable-next-line: lowercase-global
function update_selector(entry)
    -- change the combinator's visual mode
    local comb = entry.input
    local control = comb.get_or_create_control_behavior()
    local params = control.parameters

    local settings = entry.settings

    local mode = settings.mode
    if mode == 'select-input' then
        params.operation = settings.descending and '*' or '/'
    elseif mode == 'count-inputs' then
        params.operation = '-'
    elseif mode == 'random-input' then
        params.operation = '+'
    else
        params.operation = '%'
    end
    control.parameters = params
    -- premultiply this
    local newInterval = (settings.update_unit == 'seconds' and 60 or 1) * settings.update_interval
    if newInterval ~= settings.update_interval_ticks then
        settings.update_interval_ticks = newInterval
        settings.update_interval_now = true
    end

    -- clear output and internal cache
    entry.old_inputs = {}
    entry.old_outputs = {}
    entry.cb.parameters = nil
end

local function update_outputs()
    for _, entry in pairs(global.selector) do
        update_single_entry(entry)
    end
end

local filter = {{
    filter = "name",
    name = SCOMBINATOR_NAME
}}

script.on_event(defines.events.on_built_entity, on_built, filter)
script.on_event(defines.events.on_robot_built_entity, on_built, filter)
script.on_event(defines.events.script_raised_built, on_built, filter)
script.on_event(defines.events.on_player_mined_entity, on_removed, filter)
script.on_event(defines.events.on_robot_mined_entity, on_removed, filter)
script.on_event(defines.events.script_raised_destroy, on_removed, filter)
script.on_event(defines.events.on_entity_died, on_removed, filter)
script.on_event(defines.events.on_entity_destroyed, on_removed)
script.on_event(defines.events.on_entity_settings_pasted, on_paste)
script.on_event(defines.events.on_player_setup_blueprint, on_blueprint)
script.on_event(defines.events.on_tick, update_outputs)
