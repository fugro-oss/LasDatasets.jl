"""
    $(TYPEDEF)

A wrapper around a LAS dataset. Contains point cloud data in tabular format as well as metadata and VLR's/EVLR's

$(TYPEDFIELDS)
"""
mutable struct LASDataset
    """The header from the LAS file the points were extracted from"""
    const header::LasHeader
    
    """LAS point cloud data stored in a Tabular format for convenience"""
    const pointcloud::Table

    """Additional user data assigned to each point that aren't standard LAS fields"""
    _user_data::Union{Missing, FlexTable}
    
    """Collection of Variable Length Records from the LAS file"""
    const vlrs::Vector{LasVariableLengthRecord}
    
    """Collection of Extended Variable Length Records from the LAS file"""
    const evlrs::Vector{LasVariableLengthRecord}

    """Extra user bytes packed between the Header block and the first VLR of the source LAS file"""
    const user_defined_bytes::Vector{UInt8}

    """Unit conversion factors applied to each axis when the dataset is ingested. This is reversed when you save the dataset to keep header/coordinate system information consistent"""
    const unit_conversion::SVector{3, Float64}

    function LASDataset(header::LasHeader,
                        pointcloud::Table,
                        vlrs::Vector{<:LasVariableLengthRecord},
                        evlrs::Vector{<:LasVariableLengthRecord},
                        user_defined_bytes::Vector{UInt8},
                        unit_conversion::SVector{3, Float64} = NO_CONVERSION)

        # do a few checks to make sure everything is consistent between the header and other data
        point_format_from_table = get_point_format(pointcloud)
        point_format_from_header = point_format(header)
        matching_formats = point_format_from_table == point_format_from_header
        # if the formats don't match directly, at least make sure all our table columns are the same as the header columns (so it can be a subset)
        cols_in_table_are_subset = all(has_columns(point_format_from_table) .∈ Ref(has_columns(point_format_from_header)))
        @assert matching_formats || cols_in_table_are_subset "Point format in header $(point_format_from_header) doesn't match point format in Table $(point_format_from_table)"
        
        num_points_in_table = length(pointcloud)
        num_points_in_header = number_of_points(header)
        @assert num_points_in_table == num_points_in_header "Number of points in header $(num_points_in_header) doesn't match number of points in table $(num_points_in_table)"

        num_vlrs = length(vlrs)
        num_vlrs_in_header = number_of_vlrs(header)
        @assert num_vlrs == num_vlrs_in_header "Number of VLR's in header $(num_vlrs_in_header) doesn't match number of VLR's supplied $(num_vlrs)"

        num_evlrs = length(evlrs)
        num_evlrs_in_header = number_of_evlrs(header)
        @assert num_evlrs == num_evlrs_in_header "Number of EVLR's in header $(num_evlrs_in_header) doesn't match number of EVLR's supplied $(num_evlrs)"

        # make sure our unit conversions are non-zero to avoid NaN's
        @assert all(unit_conversion .> 0) "Unit conversion factors must be non-zero! Got $(unit_conversion)"

        # if points don't have an ID column assigned to them, add it in
        if :id ∉ columnnames(pointcloud)
            pointcloud = Table(pointcloud, id = collect(1:length(pointcloud)))
        end

        # need to split out our "standard" las columns from user-specific ones
        cols = collect(columnnames(pointcloud))
        these_are_las_cols = cols .∈ Ref(RECOGNISED_LAS_COLUMNS)
        las_cols = cols[these_are_las_cols]
        other_cols = cols[.!these_are_las_cols]
        las_pc = Table(NamedTuple{ (las_cols...,) }( (map(col -> getproperty(pointcloud, col), las_cols)...,) ))
        
        make_consistent_header!(header, las_pc, vlrs, evlrs, user_defined_bytes)

        user_pc = isempty(other_cols) ? missing : FlexTable(NamedTuple{ (other_cols...,) }( (map(col -> getproperty(pointcloud, col), other_cols)...,) ))
        for col ∈ other_cols
            # account for potentially having an undocumented entry - in this case, don't add an ExtraBytes VLR
            if col != :undocumented_bytes
                # need to handle the case where our user field is an array, in which case we'll need to add an ExtraBytes VLR for each array dimension
                col_type = eltype(getproperty(pointcloud, col))
                # make sure we have the appropriate types!
                check_user_type(col_type)

                # grab information about the existing ExtraBytes VLRs - need to see if we need to update them or not
                extra_bytes_vlr = extract_vlr_type(vlrs, LAS_SPEC_USER_ID, ID_EXTRABYTES)
                @assert length(extra_bytes_vlr) ≤ 1 "Found multiple Extra Bytes VLRs in LAS file!"
                if isempty(extra_bytes_vlr)
                    extra_bytes_vlr = LasVariableLengthRecord(LAS_SPEC_USER_ID, ID_EXTRABYTES, "Extra Bytes", ExtraBytesCollection())
                    # make sure we add the VLR to our collection and update any header info
                    push!(vlrs, extra_bytes_vlr)
                    header.n_vlr += 1
                    header.data_offset += sizeof(extra_bytes_vlr)
                else
                    extra_bytes_vlr = extra_bytes_vlr[1]
                end
                extra_bytes_data = get_extra_bytes(get_data(extra_bytes_vlr))
                user_field_names = Symbol.(name.(extra_bytes_data))
                user_field_types = data_type.(extra_bytes_data)

                is_vec = col_type <: SVector
                # if the column is a scalar, just check for records with name "column", else check for names "column [0]", "column [1]", etc.
                names_to_check = is_vec ? split_column_name(col, length(col_type)) : [col]
                type_to_check = is_vec ? eltype(col_type) : col_type

                for col_name ∈ names_to_check
                    # find entries with the same name and possibly same type
                    matches_name = user_field_names .== col_name
                    matches_type = user_field_types .== type_to_check
                    matches_both_idx = findfirst(matches_name .& matches_type)
                    matches_name_idx = findfirst(matches_name)
                    if !isnothing(matches_both_idx)
                        # if there's an ExtraBytes VLR with the same name and data type, we can skip
                        continue
                    elseif !isnothing(matches_name_idx)
                        # if we find one with matching name (not type), we'll need to update the header record length to account for this new type
                        header.data_record_length -= sizeof(data_type(extra_bytes_data[matches_name_idx]))
                    end
                    # now make a new ExtraBytes VLR and add it to our dataset, updating the header information as we go
                    add_extra_bytes_to_collection!(get_data(extra_bytes_vlr), col_name, eltype(type_to_check))
                    header.data_offset += sizeof(ExtraBytes)
                    header.data_record_length += sizeof(type_to_check)
                end
            end
        end
        return new(header, las_pc, user_pc, Vector{LasVariableLengthRecord}(vlrs), Vector{LasVariableLengthRecord}(evlrs), user_defined_bytes, unit_conversion)
    end
end

"""
    $(TYPEDSIGNATURES)

Create a LASDataset from a pointcloud and optionally vlrs/evlrs/user_defined_bytes, 
NO header required.
"""
function LASDataset(pointcloud::Table;
                    vlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[],
                    evlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[],
                    user_defined_bytes::Vector{UInt8} = UInt8[],
                    scale::Real = POINT_SCALE)

    point_format = get_point_format(pointcloud)
    spatial_info = get_spatial_info(pointcloud; scale = scale)

    header = LasHeader(; 
        las_version = lasversion_for_point(point_format), 
        data_format_id = UInt8(get_point_format_id(point_format)),
        data_record_length = UInt16(byte_size(point_format)),
        spatial_info = spatial_info,
    )

    make_consistent_header!(header, pointcloud, vlrs, evlrs, user_defined_bytes)

    return LASDataset(header, pointcloud, vlrs, evlrs, user_defined_bytes)
end

"""
    $(TYPEDSIGNATURES)

Extract point cloud data as a Table from a `LASDataset` `las`
"""
function get_pointcloud(las::LASDataset)
    if ismissing(las._user_data)
        return las.pointcloud
    else
        return Table(las.pointcloud, las._user_data)
    end
end

"""
    $(TYPEDSIGNATURES)

Extract the header information from a `LASDataset` `las`
"""
get_header(las::LASDataset) = las.header

"""
    $(TYPEDSIGNATURES)

Extract the set of Variable Length Records from a `LASDataset` `las`
"""
get_vlrs(las::LASDataset) = las.vlrs

"""
    $(TYPEDSIGNATURES)

Extract the set of Extended Variable Length Records from a `LASDataset` `las`
"""
get_evlrs(las::LASDataset) = las.evlrs

"""
    $(TYPEDSIGNATURES)

Extract the set of user-defined bytes from a `LASDataset` `las`
"""
get_user_defined_bytes(las::LASDataset) = las.user_defined_bytes

"""
    $(TYPEDSIGNATURES)

Get the unit factor conversion that was applied to this dataset when ingested
"""
get_unit_conversion(las::LASDataset) = las.unit_conversion

"""
    $(TYPEDSIGNATURES)

Update the offset (in Bytes) to the first EVLR in a `LASDataset` `las`
"""
function update_evlr_offset!(header::LasHeader)
    header.evlr_start = point_data_offset(header) + (number_of_points(header) * point_record_length(header))
end

update_evlr_offset!(las::LASDataset) = update_evlr_offset!(get_header(las))

function Base.show(io::IO, las::LASDataset)
    println(io, "LAS Dataset")
    println(io, "\tNum Points: $(length(get_pointcloud(las)))")
    println(io, "\tPoint Format: $(point_format(get_header(las)))")
    println(io, "\tPoint Channels: $(columnnames(las.pointcloud))")
    if !ismissing(las._user_data)
        println(io, "\tUser Fields: $(columnnames(las._user_data))")
    end
    println(io, "\tVLR's: $(length(get_vlrs(las)))")
    println(io, "\tEVLR's: $(length(get_evlrs(las)))")
    println(io, "\tUser Bytes: $(length(get_user_defined_bytes(las)))")
end

function Base.:(==)(lasA::LASDataset, lasB::LASDataset)
    # need to individually check that the header, point cloud, (E)VLRs and user bytes are all the same
    headers_equal = get_header(lasA) == get_header(lasB)
    pcA = get_pointcloud(lasA)
    pcB = get_pointcloud(lasB)
    colsA = columnnames(pcA)
    colsB = columnnames(pcB)
    pcs_equal = all([
        length(colsA) == length(colsB),
        length(pcA) == length(pcB),
        all(sort(collect(colsA)) .== sort(collect(colsB))),
        all(map(col -> all(isapprox.(getproperty(pcA, col), getproperty(pcB, col); atol = 1e-6)), colsA))
    ])
    vlrsA = get_vlrs(lasA)
    vlrsB = get_vlrs(lasB)
    vlrs_equal = all([
        length(vlrsA) == length(vlrsB),
        # account for fact that VLRS might be same but in different order
        all(map(vlr -> any(vlrsB .== Ref(vlr)), vlrsA)),
        all(map(vlr -> any(vlrsA .== Ref(vlr)), vlrsB)),
    ])
    evlrsA = get_evlrs(lasA)
    evlrsB = get_evlrs(lasB)
    evlrs_equal = all([
        length(evlrsA) == length(evlrsB),
        # account for fact that VLRS might be same but in different order
        all(indexin(evlrsA, evlrsB) .!= nothing),
        all(indexin(evlrsB, evlrsA) .!= nothing)
    ])
    user_bytes_equal = get_user_defined_bytes(lasA) == get_user_defined_bytes(lasB)
    return all([headers_equal, pcs_equal, vlrs_equal, evlrs_equal, user_bytes_equal])
end

"""
    $(TYPEDSIGNATURES)

Add a `vlr` into the set of VLRs in a LAS dataset `las`.
Note that this will modify the header content of `las`, including updating its LAS version to v1.4 if `vlr` is extended
"""
function add_vlr!(las::LASDataset, vlr::LasVariableLengthRecord)
    if is_extended(vlr) && isempty(get_evlrs(las))
        # evlrs only supported in LAS 1.4
        set_las_version!(get_header(las), v"1.4")
    end

    header = get_header(las)
    
    if is_extended(vlr)
        set_num_evlr!(header, number_of_evlrs(header) + 1)
        push!(get_evlrs(las), vlr)
        if number_of_evlrs(header) == 1
            # if this is our first EVLR, need to set the EVLR offset to point to the correct location
            update_evlr_offset!(header)
        end
    else
        set_num_vlr!(header, number_of_vlrs(header) + 1)
        push!(get_vlrs(las), vlr)
        # make sure to increase the point offset since we're cramming another VLR before the points
        header.data_offset += sizeof(vlr)
        update_evlr_offset!(header)
    end
end

"""
    $(TYPEDSIGNATURES)

Remove a `vlr` from set of VLRs in a LAS dataset `las`.
Note that this will modify the header content of `las`
"""
function remove_vlr!(las::LASDataset, vlr::LasVariableLengthRecord)
    header = get_header(las)
    if is_extended(vlr)
        set_num_evlr!(header, number_of_evlrs(header) - 1)
        evlrs = get_evlrs(las)
        matching_idx = findfirst(evlrs .== Ref(vlr))
        @assert !isnothing(matching_idx) "Couldn't find EVLR in LAS"
        deleteat!(evlrs, matching_idx)
        if isempty(evlrs)
            header.evlr_start = 0
        end
    else
        set_num_vlr!(header, number_of_vlrs(header) - 1)
        vlrs = get_vlrs(las)
        matching_idx = findfirst(vlrs .== Ref(vlr))
        @assert !isnothing(matching_idx) "Couldn't find VLR in LAS"
        deleteat!(vlrs, matching_idx)
        header.data_offset -= sizeof(vlr)
        @assert header.data_offset > 0 "Inconsistent data configuration! Got data offset of $(header.data_offset) after removing VLR"
    end
end

"""
    $(TYPEDSIGNATURES)

Mark a VLR `vlr` as superseded in a dataset `las`
"""
function set_superseded!(las::LASDataset, vlr::LasVariableLengthRecord)
    vlrs = is_extended(vlr) ? get_evlrs(las) : get_vlrs(las)
    matching_idx = findfirst(vlrs .== Ref(vlr))
    @assert !isnothing(matching_idx) "Couldn't find VLR in LAS"
    set_superseded!(vlrs[matching_idx])
end

"""
    $(TYPEDSIGNATURES)

Add a column with name `column` and set of `values` to a `las` dataset
"""
function add_column!(las::LASDataset, column::Symbol, values::AbstractVector{T}) where T
    @assert length(values) == length(las.pointcloud) "Column size $(length(values)) inconsistent with number of points $(length(las.pointcloud))"
    check_user_type(T)
    if ismissing(las._user_data)
        las._user_data = FlexTable(NamedTuple{ (column,) }( (values,) ))
    else
        # make sure if we're replacing a column we correctly update the header size
        if column ∈ columnnames(las._user_data)
            las.header.data_record_length -= sizeof(eltype(getproperty(las._user_data, column)))
        end
        Base.setproperty!(las._user_data, column, values)
    end
    las.header.data_record_length += sizeof(T)
    vlrs = get_vlrs(las)
    extra_bytes_vlrs = extract_vlr_type(vlrs, LAS_SPEC_USER_ID, ID_EXTRABYTES)
    @assert length(extra_bytes_vlrs) ≤ 1 "Found $(length(extra_bytes_vlrs)) Extra Bytes VLRs when we can only have a max of 1"
    if isempty(extra_bytes_vlrs)
        extra_bytes_vlr = LasVariableLengthRecord(LAS_SPEC_USER_ID, ID_EXTRABYTES, "Extra Bytes Records", ExtraBytesCollection())
        # make sure we add it to the dataset to account for offsets in the header etc.
        add_vlr!(las, extra_bytes_vlr)
    else
        extra_bytes_vlr = extra_bytes_vlrs[1]
    end
    if T <: SVector
        # user field arrays have to be saved as sequential extra bytes records with names of the form "column [i]" (zero indexing encouraged)
        split_col_name = split_column_name(column, length(T))
        for i ∈ 1:length(T)
            add_extra_bytes!(las, split_col_name[i], eltype(T), extra_bytes_vlr)
        end
    else
        add_extra_bytes!(las, column, T, extra_bytes_vlr)
    end
    # make sure we keep our offset to our first EVLR consistent now we've crammed more data in
    update_evlr_offset!(las)
    nothing
end

"""
    $(TYPEDSIGNATURES)

Merge a column with name `column` and a set of `values` into a `las` dataset
"""
function merge_column!(las::LASDataset, column::Symbol, values::AbstractVector)
    @assert length(values) == length(las.pointcloud) "Column size $(length(values)) inconsistent with number of points $(length(las.pointcloud))"
    if column ∈ columnnames(las.pointcloud)
        getproperty(las.pointcloud, column) .= values
    else
        add_column!(las, column, values)
    end
end

"""
    $(TYPEDSIGNATURES)

Verify that a user field data type `T` is supported as an extra byte type
"""
function check_user_type(::Type{T}) where T
    correct_type = T ∈ SUPPORTED_EXTRA_BYTES_TYPES
    correct_eltype = eltype(T) ∈ SUPPORTED_EXTRA_BYTES_TYPES
    @assert correct_type || correct_eltype "Only columns of base types static vectors of base types supported as custom columns. Got type $(T)"
end

"""
    $(TYPEDSIGNATURES)

Helper function that returns a list of extra bytes VLR field names for each entry in a user-defined array with column name `col` and dimension `dim`
"""
split_column_name(col::Symbol, dim::Integer) = map(i -> Symbol("$(col) [$(i - 1)]"), 1:dim)

"""
    $(TYPEDSIGNATURES)

Add an extra bytes VLR to a LAS dataset to document an extra user-field for points

# Arguments
* `las` : LAS dataset to add extra bytes to
* `col_name` : Name to save the user field as
* `T` : Data type for the user field (must be a base type as specified in the spec or a static vector of one of these types)
* `extra_bytes_vlr` : An Extra Bytes Collection VLR that already exists in the dataset
"""
function add_extra_bytes!(las::LASDataset, col_name::Symbol, ::Type{T}, extra_bytes_vlr::LasVariableLengthRecord{ExtraBytesCollection}) where T
    extra_bytes = get_extra_bytes(get_data(extra_bytes_vlr))
    matching_extra_bytes = findfirst(Symbol.(name.(extra_bytes)) .== col_name)
    if !isnothing(matching_extra_bytes)
        deleteat!(extra_bytes, matching_extra_bytes)
        header = get_header(las)
        header.data_offset -= (length(matching_extra_bytes) * sizeof(ExtraBytes))
        @assert header.data_offset > 0 "Inconsistent data configuration! Got data offset of $(header.data_offset) after removing Extra Bytes Record"
    end
    add_extra_bytes_to_collection!(get_data(extra_bytes_vlr), col_name, T)
    header = get_header(las)
    header.data_offset += sizeof(ExtraBytes)
end