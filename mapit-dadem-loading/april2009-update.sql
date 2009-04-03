--
-- april2009-update.sql:
-- Bump all generation numbers except those that will no longer exist.
-- Update to Unitary Authorities those that are now so, and transfer the wards across.
--
-- NB: I didn't actually run this file, but it shouldn't need to be run again,
--     and might prove useful should such a thing happen again.
--
-- Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
-- Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: april2009-update.sql,v 1.2 2009-04-03 11:51:03 matthew Exp $
--

-- generation is currently *10*

-- Only affects England, and only affects counties and districts
update area set generation_high = 11 where generation_high = 10 and ( country = 'S' or country = 'W' or country = 'N' or type not in ('CED', 'CTY', 'DIS', 'DIW') );

-- Only affects 7 counties and 37 districts
update area set generation_high = 11 where generation_high = 10 and type = 'CTY' and id not in (2216, 2219, 2223, 2238, 2245, 2248, 2250);
update area set generation_high = 11 where generation_high = 10 and type = 'CED' and parent_area_id not in (2216, 2219, 2223, 2238, 2245, 2248, 2250);

update area set generation_high = 11 where generation_high = 10 and type = 'DIS' and id not in ( 2267, 2471, 2426, 2633, 2266, 2265, 2634, 2300, 2298, 2628, 2627, 2425, 2472, 2303, 2252, 2473, 2297, 2302, 2422, 2269, 2402, 2399, 2635, 2632, 2268, 2631, 2423, 2299, 2400, 2301, 2424, 2401, 2470, 2264, 2254, 2270, 2253 );
update area set generation_high = 11 where generation_high = 10 and type = 'DIW' and parent_area_id not in ( 2267, 2471, 2426, 2633, 2266, 2265, 2634, 2300, 2298, 2628, 2627, 2425, 2472, 2303, 2252, 2473, 2297, 2302, 2422, 2269, 2402, 2399, 2635, 2632, 2268, 2631, 2423, 2299, 2400, 2301, 2424, 2401, 2470, 2264, 2254, 2270, 2253 );

-- Durham, Shropshire, Wiltshire, Northumberland, Cornwall CC, and Bedford BC become unitary authorities
update area set type='UTA', generation_high=11 where generation_high=10 and id in (2223, 2238, 2245, 2248, 2250, 2253);
update area set type='UTW', generation_high=11 where generation_high=10 and parent_area_id in (2223, 2238, 2245, 2248, 2250, 2253);

-- Creation of new Chesire unitary authorities
insert into area (id, parent_area_id, unit_id, ons_code, type, country, generation_low, generation_high) values (21068, null, null, '00EW', 'UTA', 'E', 11, 11);
insert into area_name (area_id, name_type, name) values (21068, 'O', 'Cheshire West and Chester');
insert into area_name (area_id, name_type, name) values (21068, 'F', 'Cheshire West and Chester Council');
insert into area (id, parent_area_id, unit_id, ons_code, type, country, generation_low, generation_high) values (21069, null, null, '00EQ', 'UTA', 'E', 11, 11);
insert into area_name (area_id, name_type, name) values (21069, 'O', 'Cheshire East');
insert into area_name (area_id, name_type, name) values (21069, 'F', 'Cheshire East Council');
-- Put all old Cheshire wards in new Cheshire UAs
update area set type='UTW', generation_high=11, parent_area_id=21068 where id in ( 14508, 14526, 14507, 14511, 14525, 14523, 14515, 14544, 14542, 14530, 14529, 14548, 14547, 14504, 14541, 14532, 14539, 14524, 14518, 14520, 14540, 14552, 14545, 14538 );
update area set type='UTW', generation_high=11, parent_area_id=21069 where id in ( 14503, 14505, 14553, 14521, 14517, 14513, 14512, 14519, 14534, 14546, 14522, 14531, 14551, 14549, 14527, 14536, 14537, 14514, 14516, 14543, 14509, 14550, 14528, 14510, 14535, 14506, 14533 );

-- Creation of new Central Bedfordshire
insert into area (id, parent_area_id, unit_id, ons_code, type, country, generation_low, generation_high) values (21070, null, null, '00KC', 'UTA', 'E', 11, 11);
insert into area_name (area_id, name_type, name) values (21070, 'O', 'Central Bedfordshire');
insert into area_name (area_id, name_type, name) values (21070, 'F', 'Central Bedfordshire Council');
-- Put old Bedfordshire CC wards that are within Central Bedfordshire's boundary (so not ones within Bedford) in new UA
update area set type='UTW', generation_high=11, parent_area_id=21070 where id in ( 14467, 14466, 14480, 14473, 14479, 14457, 14478, 14502, 14460, 14471, 14486, 14481, 14483, 14496, 14492, 14498, 14468, 14476, 14464, 14489, 14470, 14477, 14485, 14469, 14458, 14490, 14493, 14482 );

