-- Execute the actual pinned upstream import transform, not a reimplementation.
dofile(arg[1] .. '/lua/graph.lua')
local cases = {
 {'verified_motorcycle_override', {highway='track',access='no',motorcycle='yes'}},
 {'private', {highway='unclassified',access='private'}},
 {'unknown_track', {highway='track'}},
 {'unknown_path', {highway='path'}},
 {'motorcycle_direction_denied', {highway='unclassified',['motorcycle:forward']='no',motorcycle='yes'}},
 {'motorcycle_yes_motorvehicle_forward_no', {highway='unclassified',motorcycle='yes',['motor_vehicle:forward']='no'}},
 {'destination', {highway='unclassified',access='destination'}},
 {'explicit_denied', {highway='unclassified',motorcycle='no'}},
}
for _,c in ipairs(cases) do
 local count=0; for k,v in pairs(c[2]) do count=count+1 end
 local filter,t=ways_proc(c[2],count)
 print(c[1] .. '\tfilter=' .. tostring(filter) .. '\tforward=' .. tostring(t.motorcycle_forward) .. '\tbackward=' .. tostring(t.motorcycle_backward) .. '\tprivate=' .. tostring(t.private) .. '\tdestination=' .. tostring(t.destination_only))
end
