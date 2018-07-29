
--[[ taken from src/mg_schematic.cpp:
        Minetest Schematic File Format

        All values are stored in big-endian byte order.
        [u32] signature: 'MTSM'
        [u16] version: 3
        [u16] size X
        [u16] size Y
        [u16] size Z
        For each Y:
                [u8] slice probability value
        [Name-ID table] Name ID Mapping Table
                [u16] name-id count
                For each name-id mapping:
                        [u16] name length
                        [u8[] ] name
        ZLib deflated {
        For each node in schematic:  (for z, y, x)
                [u16] content
        For each node in schematic:
                [u8] probability of occurance (param1)
        For each node in schematic:
                [u8] param2
        }

        Version changes:
        1 - Initial version
        2 - Fixed messy never/always place; 0 probability is now never, 0xFF is always
        3 - Added y-slice probabilities; this allows for variable height structures
--]]

--handle_schematics = {}

-- taken from https://github.com/MirceaKitsune/minetest_mods_structures/blob/master/structures_io.lua (Taokis Sructures I/O mod)
-- gets the size of a structure file
-- nodenames: contains all the node names that are used in the schematic
-- on_constr: lists all the node names for which on_construct has to be called after placement of the schematic
handle_schematics.analyze_mts_file = function( path )
	local size = { x = 0, y = 0, z = 0, version = 0 }
	local version = 0;

	local file, err = save_restore.file_access(path..'.mts', "rb")
	if (file == nil) then
		return nil
	end
--print('[handle_schematics] Analyzing .mts file '..tostring( path..'.mts' ));
--if( not( string.byte )) then
--	print( '[handle_schematics] Error: string.byte undefined.');
--	return nil;
--end

	-- thanks to sfan5 for this advanced code that reads the size from schematic files
	local read_s16 = function(fi)
		return string.byte(fi:read(1)) * 256 + string.byte(fi:read(1))
	end

	local function get_schematic_size(f)
		-- make sure those are the first 4 characters, otherwise this might be a corrupt file
		if f:read(4) ~= "MTSM" then
			return nil
		end
		-- advance 2 more characters
		local version = read_s16(f); --f:read(2)
		-- the next characters here are our size, read them
		return read_s16(f), read_s16(f), read_s16(f), version
	end

	size.x, size.y, size.z, size.version = get_schematic_size(file)
	
	-- read the slice probability for each y value that was introduced in version 3
	if( size.version >= 3 ) then
		-- the probability is not very intresting for buildings so we just skip it
		file:read( size.y );
	end


	-- this list is not yet used for anything
	local nodenames = {};
	-- this list is needed for calling on_construct after place_schematic
	local on_constr = {};
	-- nodes that require after_place_node to be called
	local after_place_node = {};

	-- after that: read_s16 (2 bytes) to find out how many diffrent nodenames (node_name_count) are present in the file
	local node_name_count = read_s16( file );

	for i = 1, node_name_count do

		-- the length of the next name
		local name_length = read_s16( file );
		-- the text of the next name
		local name_text   = file:read( name_length );

		table.insert( nodenames, name_text );
		local node_def = handle_schematics.node_defined( name_text );
		-- in order to get this information, the node has to be defined and loaded
		if( node_def and node_def.on_construct) then
			table.insert( on_constr, name_text );
		end
		-- some nodes need after_place_node to be called for initialization
		if( node_def and node_def.after_place_node) then
			table.insert( after_place_node, name_text );
		end
	end

	local rotated = 0;
	local burried = 0;
	local parts = path:split('_');
	if( parts and #parts > 2 ) then
		if( parts[#parts]=="0" or parts[#parts]=="90" or parts[#parts]=="180" or parts[#parts]=="270" ) then
			rotated = tonumber( parts[#parts] );
			burried = tonumber( parts[ #parts-1 ] );
			if( not( burried ) or burried>20 or burried<0) then
				burried = 0;
			end
		end
	end

	-- decompression was recently added; if it is not yet present, we need to use normal place_schematic
	if( minetest.decompress == nil) then
		file.close(file);
		return nil; -- normal place_schematic is no longer supported as minetest.decompress is now part of the release version of minetest
--		return { size = { x=size.x, y=size.y, z=size.z}, nodenames = nodenames, on_constr = on_constr, after_place_node = after_place_node, rotated=rotated, burried=burried, scm_data_cache = nil };
	end

	local compressed_data = file:read( "*all" );
	local data_string = minetest.decompress(compressed_data, "deflate" );
	file.close(file)

	-- find out which id air has in this particular schematic
	local is_air = 0;
	for i,v in ipairs( nodenames ) do
		if( v == 'air' ) then
			is_air = i;
		end
	end

	-- some mods (like mg_villages) might be intrested in the number of npc that can live here
	local bed_count = 0;
	local bed_list = {};

	local p2offset = (size.x*size.y*size.z)*3;
	local i = 1;
	local scm = {};
	for z = 1, size.z do
	for y = 1, size.y do
	for x = 1, size.x do
		if( not( scm[y] )) then
			scm[y] = {};
		end
		if( not( scm[y][x] )) then
			scm[y][x] = {};
		end
		local id = string.byte( data_string, i ) * 256 + string.byte( data_string, i+1 );
		i = i + 2;
		local p2 = string.byte( data_string, p2offset + math.floor(i/2));
		id = id+1;

		if( id ~= is_air ) then
			scm[y][x][z] = {id, p2};
			if( handle_schematics.bed_node_names[ nodenames[ id ]]) then
				bed_count = bed_count + 1;
				table.insert( bed_list, {x=x, y=y, z=z, p2, id});
			end
		end
	end
	end
	end

	--print( "MTS FILE "..tostring(path)..": "..tostring( bed_count ).." beds.");
	return { size = { x=size.x, y=size.y, z=size.z}, nodenames = nodenames, on_constr = on_constr, after_place_node = after_place_node, rotated=rotated, burried=burried, scm_data_cache = scm, bed_count = bed_count, bed_list = bed_list };
end



handle_schematics.store_mts_file = function( path, data )

	data.nodenames[ #data.nodenames+1 ] = 'air';

	local file, err = save_restore.file_access(path..'.mts', "wb")
	if (file == nil) then
		return nil
	end

	local write_s16 = function( fi, a )
		fi:write( string.char( math.floor( a/256) ));
		fi:write( string.char( a%256 ));	
	end

	data.size.version = 3; -- we only support version 3 of the .mts file format

	file:write( "MTSM" );
	write_s16( file, data.size.version ); 
	write_s16( file, data.size.x );
	write_s16( file, data.size.y );
	write_s16( file, data.size.z );

	
	-- set the slice probability for each y value that was introduced in version 3
	if( data.size.version >= 3 ) then
		-- the probability is not very intresting for buildings so we just skip it
		for i=1,data.size.y do
			file:write( string.char(255) );
		end
	end

	-- set how many diffrent nodenames (node_name_count) are present in the file
	write_s16( file, #data.nodenames );

	for i = 1, #data.nodenames do
		-- the length of the next name
		write_s16( file, string.len( data.nodenames[ i ] ));
		file:write( data.nodenames[ i ] );
	end

	-- this string will later be compressed
	local node_data = "";

	-- actual node data
	for z = 1, data.size.z do
	for y = 1, data.size.y do
	for x = 1, data.size.x do
		local a = data.scm_data_cache[y][x][z];
		if( a and type( a ) == 'table') then
			node_data = node_data..string.char( math.floor( a[1]/256) )..string.char( a[1]%256-1);	
		else
			node_data = node_data..string.char( 0 )..string.char( #data.nodenames-1 );
		end
	end
	end
	end

	-- probability of occurance
	for z = 1, data.size.z do
	for y = 1, data.size.y do
	for x = 1, data.size.x do
		node_data = node_data..string.char( 255 );
	end
	end
	end

	-- param2
	for z = 1, data.size.z do
	for y = 1, data.size.y do
	for x = 1, data.size.x do
		local a = data.scm_data_cache[y][x][z];
		if( a and type( a) == 'table' ) then
			node_data = node_data..string.char( a[2] );	
		else
			node_data = node_data..string.char( 0 );	
		end
	end
	end
	end

	local compressed_data = minetest.compress( node_data, "deflate" );
	file:write( compressed_data );
	file.close(file);
	print('SAVING '..path..'.mts (converted from .we).'); 
end


-- read .mts (minetest schematic), .we (WorldEdit) and .schematic (MC schematic format) files
-- 	file_name:     file name with full path but without file name exstension
--	origin_offset: .we files may have this defined if their start is not at 0,0,0
--	store_as_mts:  if set to true: convert files of any other types and store them
--	               as .mts files additionally (speeds up usage at later server starts)
--	building_data: Table that may contain additional information about the building; in particular:
--	                     orients:  list of allowed rotations for this schematic; may be {0,1,2,3}
--	                               for a building that looks at a street ok no matter how it is rotated;
--	                               may be set to i.e. {2} if the building is initially rotated by 180
--	                               degree and has a front door
--	                     yoff:     How deep is the building burried? Automaticly determined for .mts
--	                               files created by this mod but otherwise ought to be provided.
--	               Entries of this table are returned in the return value if possible.
--	no_build_chest_entry: If set to true: Do not add an entry for this building in the build_chest.
--	               Useful when manually adding diffrently structured entries (as in i.e. mg_villages)
--	               or when the entry would be temporal only.
-- Returns a table that contains the necessary information for spawning the building.
-- Returns nil if reading of the file failed.
handle_schematics.analyze_file = function( file_name, origin_offset, store_as_mts, building_data,no_build_chest_entry)
	if( not( building_data )) then
		building_data = {};
	end
	-- determine the file_name from building_data if possible
	if( not( file_name ) and building_data.mts_path and building_data.scm ) then
		file_name = building_data.mts_path .. building_data.scm;
	elseif( not( file_name )) then
		print("[handle_schematics] ERROR: No file name given to analyze.");
		return;
	end

	local res  = handle_schematics.analyze_mts_file( file_name ); 
	-- alternatively, read the mts file
	if( not( res )) then
		res = handle_schematics.analyze_we_file( file_name, origin_offset );
		if( not( res )) then
			res = handle_schematics.analyze_mc_schematic_file( file_name );
		end
		-- print error message only if all import methods failed
		if( not( res )) then
			print('[handle_schematics] ERROR: Failed to import file \"'..tostring( file_name )..'\"[.mts|.we|.wem|.schematic]');
		-- convert to .mts for later usage
                elseif( store_as_mts ) then
			handle_schematics.store_mts_file( store_as_mts, res );
		end

		-- .we and .schematic do not provide on_construct/after_palce_node
		-- (they have metadata instead)
		res.on_constr = {};
		res.after_place_node = {};
		for _, name_text in res.nodenames do
			local node_def = handle_schematics.node_defined( name_text );
			if( node_def and node_def.on_construct) then
				table.insert( on_constr, name_text );
			end
			if( node_def and node_def.after_place_node) then
				table.insert( after_place_node, name_text );
			end
		end
	end

	-- the building cannot be used if its size remains unknown
	if( not( res ) or not(res.size) or not(res.size.x)) then
		return nil;
	end

	-- the file has to be placed with minetest.place_schematic(...)
	res.is_mts = 1;

	-- the actual functions for placing use these for accessing the size
	res.sizex = res.size.x;
	res.sizez = res.size.z;
	res.ysize = res.size.y;

	-- these values remain unchanged
	-- res.bed_count:        How many beds does the building contain?
	-- res.bed_list:         And where are the beds placed in the original schematic?
	-- res.rotated:          Was the building stored in a rotated way?
	-- res.nodenames:        Which nodes are part of the building?
	-- res.on_constr:        For which nodes (nodenames only) do we need to call on_constuct?
	-- res.after_place_node: For which nodes (nodenames only) do we need to call after_palce_node?
	-- res.door_a:           Where can doors of type _a be found?
	-- res.door_b:           Where can doors of type _b be found?
	-- res.metadata:         Metadata; Only provided by .we files.

	-- some buildings may be rotated
	if( not( building_data.orients ) and res.rotated ) then
		res.orients = {};
		if(     res.rotated == 0 ) then
			res.orients[1] = 0;
		elseif( res.rotated == 90 ) then
			res.axis = 1; -- important when mirroring
			res.orients[1] = 1;
		elseif( res.rotated == 180 ) then
			res.orients[1] = 2;
		elseif( res.rotated == 270 ) then
			res.orients[1] = 3;
			res.axis = 1; -- important when mirroring
		end
	end

	if( not( building_data.yoff ) and res.burried ) then
		res.yoff = 1-res.burried;
	end

	-- the file has been read already
	if( res.scm_data_cache ) then
		res.is_mts = 0;
	end

	-- copy all the values from building_data over to res for later use; that
	-- might i.e. be information of where/how this building can be used by the mod
	-- (mod internal information)
	for k,v in pairs( building_data ) do
		-- do not overwrite any values
		if( not( res[ k ])) then
			res[ k ] = v;
		end
	end

	-- make the building as such available for the build_chest;
	-- cache all data (including res.scm_data_cache)
	-- TODO: what if the building was already stored by another mod?
	-- TODO: really cache all data?
	if( build_chest and build_chest.add_building ) then
		build_chest.add_building( file_name, res );
	end
	-- add the building to the menu list for the build chest
	if( build_chest and build_chest.add_entry and not(no_build_chest_entry) and building_data.scm) then
		local modname = minetest.get_current_modname();
		build_chest.add_entry( {'main', modname, modname, building_data.scm, file_name });
	end

	return res;
end
