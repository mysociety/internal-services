--
-- 2009-12-manual-update.sql:
-- So we know of no changes in Scotland or Northern Ireland.
-- Bump all their generation numbers rather than run them through the unnecessary process.
--
-- Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
-- Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: 2009-12-manual-update.sql,v 1.1 2009-12-21 17:34:00 matthew Exp $
--

-- current generation is currently *11*

-- Only affects England and Wales
update area set generation_high = 12 where generation_high = 11 and ( country = 'S' or country = 'N' );

-- Update the ONS codes and names for the areas from April 2009

-- Bedford
update area set ons_code='00KB' where ons_code='09UD';
update area_name set name='Bedford' where name_type='O' and area_id=2253;
update area_name set name=replace(name, ' ED', ' Ward') where name_type='O' and area_id in (select id from area where parent_area_id in (21068,21069,21070));

-- Cornwall
update area set ons_code='00HE' where ons_code='15';
update area_name set name='Cornwall' where name='Cornwall County';
update area_name set name='Cornwall Council' where area_id=2250 and name_type in ('M','F');

-- Durham
update area set ons_code='00EJ' where ons_code='20';
update area_name set name='County Durham' where name='Durham County';

-- Northumberland
update area set ons_code='00EM' where ons_code='35';
update area_name set name='Northumberland' where area_id=2248 and name_type = 'O';

-- Shropshire
update area set ons_code='00GG' where ons_code='39';
update area_name set name='Shropshire' where area_id=2238 and name_type = 'O';
update area_name set name='Shropshire Council' where area_id=2238 and name_type in ('M','F');

-- Wiltshire
update area set ons_code='00HY' where ons_code='46';
update area_name set name='Wiltshire' where area_id=2245 and name_type = 'O';
update area_name set name='Wiltshire Council' where area_id=2245 and name_type in ('M','F');

-- Isles of Scilly had a ONS code change too
update area set ons_code='00HF' where ons_code='15UH';

-- A few ward name changes
update area_name set name = 'Godmanchester and Huntingdon East ED' where name_type='O' and area_id=16016; -- Godmanchester
update area_name set name = 'St. Neots Eaton Socon and Eynesbury ED' where name_type='O' and area_id=16022; -- was St Neots Eaton Socon
update area_name set name = 'Halton Castle Ward' where name_type='O' and area_id=10557; -- was Castlefields
update area_name set name = 'Hollingdean and Stanmer Ward' where name_type='O' and area_id=11448; -- was Hollingbury and Stanmer Ward
update area_name set name = 'Randwick, Whiteshill and Ruscombe Ward' where name_type='O' and area_id=4491; -- was Over Stroud
update area_name set name = 'Annandale East and Eskdale' where name_type='F' and area_id=20679; -- was Annandale East

