-- Private verified-attribute adapter, OSRM API v4. Not a general OSM importer.
api_version = 4
function setup()
 return {properties={weight_name='dirt',weight_precision=1,use_turn_restrictions=true,continue_straight_at_waypoint=true,max_speed_for_map_matching=100},
 restrictions={'motorcycle','motor_vehicle','vehicle'},classes={'unknown'},excludable={{unknown=true}}}
end
function process_node(profile,node,result) end
function process_way(profile,way,result)
 if not way:get_value_by_key('highway') then return end
 local surface=way:get_value_by_key('dirt:surface')
 local road=way:get_value_by_key('highway')
 local objective=os.getenv('DIRT_OBJECTIVE') or 'dirt10'
 local wander=tonumber(os.getenv('DIRT_WANDER') or '1')
 local factor=1
 if objective=='paved' then
  local factors={primary=4,primary_link=4,trunk=8,trunk_link=8,motorway=32,motorway_link=32,service=6}
  factor=(factors[road] or 1)*(surface=='paved' and 1 or 100)
 elseif objective~='distance' then
  factor=((road=='motorway' or road=='motorway_link') and 8 or 1)*(surface=='dirt' and 1 or (objective=='dirt30' and 30 or 10))
 end
 factor=factor+30*(1-wander)^2
 result.name=way:get_value_by_key('name')
 for _,direction in ipairs({'forward','backward'}) do
  local code=tonumber(way:get_value_by_key('dirt:access:'..direction) or '0')
  if code==0 or code==1 then
   result[direction..'_mode']=mode.driving
   result[direction..'_speed']=36
   result[direction..'_rate']=1/factor
   if code==1 then result[direction..'_classes']['unknown']=true end
  end
 end
end
function process_turn(profile,turn) turn.duration=0;turn.weight=0 end
return {setup=setup,process_node=process_node,process_way=process_way,process_turn=process_turn}
