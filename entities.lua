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

        previous_signals = {},

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

local function inputs_are_unchanged(entry)
	-- Try to short-circuit if the selector setting is count-inputs or stack-size.
	-- select-input cannot be handled this way, because it needs to see red and green wires separately
	local signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)

	if signals == nil then
		if #entry.previous_signals == 0 then
			return true
		else
			entry.previous_signals = {}
			return false
		end
	end

	if #signals ~= #entry.previous_signals then
		entry.previous_signals = {}
		for i = 1, #signals do
			entry.previous_signals[i] = { name = signals[i].signal.name }
		end
		return false
	end

	local inputs_match = true

	for i = 1, #signals do
		local signal = signals[i]
		if entry.previous_signals[i].name ~= signal.signal.name then
			entry.previous_signals[i] = { name = signal.signal.name }
			inputs_match = false
		end
	end

	return inputs_match
end

local function update_single_entry(entry)
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
    elseif (settings.mode == 'count-inputs' or settings.mode == 'stack-size') and inputs_are_unchanged(entry) then
        return
    end

    local signals

    local mode = settings.mode
    if mode == 'select-input' then
        -- if a signal is set, read from the green wire.
        local index = settings.index
        if settings.index_signal ~= nil then
            signals = get_wire(entry.input, defines.wire_type.green)
            if signals == nil then
                entry.cb.parameters = nil
                return
            end
            local red = get_wire(entry.input, defines.wire_type.red)
            -- try to find the index signal
            if red == nil then
                index = 0
            else
                for _, redSig in pairs(red) do
                    if redSig.signal.type == settings.index_signal.type and redSig.signal.name == settings.index_signal.name then
                        index = redSig.count
                        goto found
                    end
                end
                -- not found, assume value is 0
                index = 0
                ::found::
            end
        else
            -- otherwise, just read from both wires.
            -- this may be a bit confusing ... but oh well
            signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)
            if signals == nil then
                entry.cb.parameters = nil
                return
            end
        end
        -- if out of range, no need to sort. 
        if index >= #signals or index < 0 then
            entry.cb.parameters = nil
            return
        end
        local s = SORTS[1]
        if not settings.descending then s = SORTS[2] end
        table.sort(signals, s)
        local sig = signals[index+1]
        entry.cb.parameters = {{
            signal = sig.signal,
            count = sig.count,
            index = 1
        }}
    elseif mode == 'count-inputs' then
        signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)
        if signals == nil or settings.count_signal == nil then
            entry.cb.parameters = nil
        else
            entry.cb.parameters = {{
                signal = settings.count_signal,
                count = #signals,
                index = 1
            }}
        end
    elseif mode == 'random-input' then
        signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)
        if signals == nil then
            entry.previous_signals = {}
            entry.cb.parameters = nil
            return
        end

        -- if only one signal then output it
        if #signals == 1 then
            entry.previous_signals = {{
                signal = signals[1].signal,
                count = signals[1].count,
                index = 1
            }}
            entry.cb.parameters = entry.previous_signals
            return
        end

        -- otherwise, choose a random signal.
        local signal = signals[global.rng(#signals)]

        -- if random_unique is set, do we need to re-run the rng?
        if settings.random_unique and #entry.previous_signals ~= 0 then
            local previous = entry.previous_signals[1].signal
            while signal.signal.name == previous.name and signal.signal.type == previous.type do
                signal = signals[global.rng(#signals)]
            end
        end
        
        entry.previous_signals = {{
            signal = signal.signal,
            count = signal.count,
            index = 1
        }}
        entry.cb.parameters = entry.previous_signals
    else
        -- stack-size
        signals = entry.input.get_merged_signals(defines.circuit_connector_id.combinator_input)
        if signals == nil then
            entry.cb.parameters = nil
            return
        end
        local params = {}
        local i = 1
        for _, signal in pairs(signals) do
            if signal.signal.type == "item" then
                local item = game.item_prototypes[signal.signal.name]
                if item ~= nil then
                    params[i] = {
                        signal = signal.signal,
                        count = item.stack_size,
                        index = i
                    }
                    i = i + 1
                end
            end
        end
        entry.cb.parameters = params
    end
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
