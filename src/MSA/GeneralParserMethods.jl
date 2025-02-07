# Mappings
# ========

 # It checks sequence lengths
function _fill_aln_seq_ann!(aln, seq_ann::Vector{String}, seq::String,
                            init::Int, nres::Int, i)
    if length(seq) != nres
        throw(ErrorException(string(
            "There is an aligned sequence with different number of columns [ ",
            length(seq), " != ", nres, " ]:\n", seq)))
    end
    j = 1
    @inbounds for res in seq
        aln[j,i] = res
        if res != '-' && res != '.'
            seq_ann[j] = string(init)
            init += 1
        else
            seq_ann[j] = ""
        end
        j += 1
    end
    join(seq_ann, ','), init - 1
end

function _to_msa_mapping(sequences::Array{String,1})
    nseq = size(sequences,1)
    nres = length(sequences[1])
    aln = Array{Residue}(undef, nres, nseq)
    mapp = Array{String}(undef, nseq)
    seq_ann = Array{String}(undef, nres)
    for i in 1:nseq
        # It checks sequence lengths
        mapp[i], last = _fill_aln_seq_ann!(aln, seq_ann, sequences[i], 1, nres, i)
    end
    msa = NamedArray(permutedims(aln, [2,1]))
    # MSA constructors adds dimension names
    # setdimnames!(msa, ("Seq","Col"))
    (msa, mapp)
end

function _to_msa_mapping(sequences::Array{String,1}, ids)
    nseq = size(sequences,1)
    nres = length(sequences[1])
    aln = Array{Residue}(undef, nres, nseq)
    mapp = Array{String}(undef, nseq)
    seq_ann = Array{String}(undef, nres)
    sep = r"/|-"
    for i in 1:nseq
        fields = split(ids[i], sep)
        init  = length(fields) == 3 ? parse(Int, fields[2]) : 1
        mapp[i], last = _fill_aln_seq_ann!(aln, seq_ann, sequences[i], init, nres, i)
        if length(fields) == 3
            end_coordinate = parse(Int, fields[3])
            if last != end_coordinate
                throw(ErrorException(string("The last residue number ", last,
                    " in sequence ", i, " isn't the end coordinate ", end_coordinate)))
            end
        end
    end
    msa = NamedArray(permutedims(aln, [2,1]),
        (   OrderedDict{String,Int}(zip(ids, 1:nseq)),
            OrderedDict{String,Int}(string(i) => i for i in 1:nres) ),
        ("Seq","Col"))
    msa, mapp
end

# Check sequence length
# ---------------------
#
# Functions to be used in _pre_read... functions
# This checks that all the sequences have the same length,
# Use _convert_to_matrix_residues(SEQS, _get_msa_size(SEQS))
# instead of convert(Matrix{Residue},SEQS)
# if SEQS was generated by pre_read... calling _check_seq_...

function _check_seq_and_id_number(IDS, SEQS)
    if length(SEQS) != length(IDS)
        throw(ErrorException(
            "The number of sequences is different from the number of names."))
    end
end

function _check_seq_len(IDS, SEQS)
    N = length(SEQS)
    _check_seq_and_id_number(IDS, SEQS)
    if N > 1
        first_length = length(SEQS[1])
        for i in 2:N
            len = length(SEQS[i])
            if len != first_length
                throw(ErrorException(
                    "The sequence $(IDS[i]) has $len residues. " *
                    "$first_length residues are expected."))
            end
        end
    end
end

# NamedArray{Residue,2} and AnnotatedMultipleSequenceAlignment generation
# -----------------------------------------------------------------------

function _ids_ordered_dict(ids, nseq::Int)
        dict = OrderedDict{String,Int}()
        sizehint!(dict, length(ids))
        for (i, id) in enumerate(ids)
            dict[id] = i
        end
        if length(dict) < nseq
            throw(ArgumentError(
                "There are less unique sequence identifiers than sequences."))
        end
        return dict
end

function _colnumber_ordered_dict(nres::Int)
        dict = OrderedDict{String,Int}()
        sizehint!(dict, nres)
        for i in 1:nres
            dict[string(i)] = i
        end
        return dict
end

function _generate_named_array(SEQS, IDS)::NamedResidueMatrix{Array{Residue,2}}
    nseq, nres = _get_msa_size(SEQS)
    msa = _convert_to_matrix_residues(SEQS, (nseq, nres))
    NamedResidueMatrix{Array{Residue,2}}(msa,
        (   _ids_ordered_dict(IDS, nseq), _colnumber_ordered_dict(nres)  ),
        ("Seq","Col"))
end

function _generate_annotated_msa(annot::Annotations, IDS::Vector{String},
                                 SEQS, keepinserts, generatemapping,
                                 useidcoordinates, deletefullgaps)
    if keepinserts
        _keepinserts!(SEQS, annot)
    end
    from_hcat = getannotfile(annot, "HCat", "") != ""
    if generatemapping
        if useidcoordinates && hascoordinates(IDS[1])
            MSA, MAP = _to_msa_mapping(SEQS, IDS)
        else
            MSA, MAP = _to_msa_mapping(SEQS)
            setnames!(MSA, IDS, 1)
        end
        if getannotfile(annot, "ColMap", "") != ""
            mssg = if from_hcat
                """
                The file came from an MSA concatenation and has column annotations.
                The information about the column numbers before concatenation will be lost 
                because of the generatemapping keyword argument.
                """ 
            else 
                "The file already has column annotations. ColMap will be replaced."
            end
            @warn """
            $mssg You can use generatemapping=false to keep the file mapping annotations.
            """
        end
        setannotfile!(annot, "NCol", string(size(MSA,2)))
        setannotfile!(annot, "ColMap", join(vcat(1:size(MSA,2)), ','))
        N = length(IDS)
        if N > 0 && getannotsequence(annot,IDS[1],"SeqMap","") != ""
            @warn("""
            The file already has sequence mappings for some sequences. SeqMap will be replaced.
            You can use generatemapping=false to keep the file sequence mapping annotations.
            """)
        end
        for i in 1:N
            setannotsequence!(annot, IDS[i], "SeqMap", MAP[i])
        end
    else
        MSA = _generate_named_array(SEQS, IDS)
        colmap = getannotfile(annot,"ColMap","")
        cols = if colmap != ""
            map(String, split(colmap, ','))
        else
            String[]
        end
        if !isempty(cols)
            if from_hcat
                msas = map(String, split(getannotfile(annot, "HCat"), ','))
                setnames!(MSA, String["$(m)_$c" for (m, c) in zip(msas, cols)], 2)
            else
                setnames!(MSA, cols, 2)
            end
        end
    end
    msa = AnnotatedMultipleSequenceAlignment(MSA, annot)
    if deletefullgaps
        deletefullgapcolumns!(msa)
    end
    msa
end


# Matrix{Residue} and NamedArray{Residue,2}
# -----------------------------------------
#
# This checks that all the sequences have the same length
#

function _strings_to_msa(::Type{NamedArray{Residue,2}}, seqs::Vector{String},
                        deletefullgaps::Bool)
    msa = NamedArray(convert(Matrix{Residue}, seqs))
    setdimnames!(msa, ("Seq","Col"))
    if deletefullgaps
        return( deletefullgapcolumns(msa) )
    end
    msa
end

function _strings_to_msa(::Type{Matrix{Residue}}, seqs::Vector{String},
                        deletefullgaps::Bool)
    msa = convert(Matrix{Residue}, seqs)
    if deletefullgaps
        return( deletefullgapcolumns(msa) )
    end
    msa
end

# Unsafe: It doesn't check sequence lengths
# Use it after _pre_read... calling _check_seq_...
function _strings_to_matrix_residue_unsafe(seqs::Vector{String}, deletefullgaps::Bool)
    msa = _convert_to_matrix_residues(seqs, _get_msa_size(seqs))
    if deletefullgaps
        return( deletefullgapcolumns(msa) )
    end
    msa
end


# Delete Full of Gap Columns
# ==========================

"Deletes columns with 100% gaps, this columns are generated by inserts."
function deletefullgapcolumns!(msa::AbstractMultipleSequenceAlignment, annotate::Bool=true)
    mask = columngapfraction(msa) .!= one(Float64)
    number = sum(.~mask)
    if number != 0
        annotate && annotate_modification!(msa, string("deletefullgaps!  :  Deletes ",
            number, " columns full of gaps (inserts generate full gap columns on MIToS ",
            "because lowercase and dots are not allowed)"))
        filtercolumns!(msa, mask, annotate)
    end
    msa
end

function deletefullgapcolumns(msa::AbstractMatrix{Residue})
    mask = columngapfraction(msa) .!= one(Float64)
    number = sum(.~mask)
    if number != 0
        return(filtercolumns(msa, mask))
    end
    msa
end

function deletefullgapcolumns(msa::AbstractMultipleSequenceAlignment, annotate::Bool=true)
    deletefullgapcolumns!(copy(msa), annotate)
end

@doc """
`parse(io, format[, output; generatemapping, useidcoordinates, deletefullgaps])`

The keyword argument `generatemapping` (`false` by default) indicates if the mapping of the
sequences ("SeqMap") and columns ("ColMap") and the number of columns in the original MSA
("NCol") should be generated and saved in the annotations. If `useidcoordinates` is `true`
(default: `false`) the sequence IDs of the form "ID/start-end" are parsed and used for
determining the start and end positions when the mappings are generated. `deletefullgaps`
(`true` by default) indicates if columns 100% gaps (generally inserts from a HMM) must be
removed from the MSA.
""" parse

# Keepinserts
# ===========

"""
Function to keep insert columns in `parse`. It uses the first sequence to generate the
"Aligned" annotation, and after that, convert all the characters to uppercase.
"""
function _keepinserts!(SEQS, annot)
    aligned = map(SEQS[1]) do char
        isuppercase(char) || char == '-' ? '1' : '0'
    end
    setannotcolumn!(annot, "Aligned", aligned)
    map!(uppercase, SEQS, SEQS)
end
