## Extensions of JuliaSyntax to cover TypedSyntaxNode

function Base.show(io::IO, ::MIME"text/plain", node::TypedSyntaxNode; show_byte_offsets=false)
    println(io, "line:col│$(show_byte_offsets ? " byte_range  │" : "") tree                                   │ type")
    JuliaSyntax._show_syntax_node(io, Ref{Union{Nothing,String}}(nothing), node, "", show_byte_offsets)
end

function JuliaSyntax._show_syntax_node(io, current_filename, node::TypedSyntaxNode, indent, show_byte_offsets)
    fname = node.source.filename
    line, col = source_location(node.source, node.position)
    posstr = "$(lpad(line, 4)):$(rpad(col,3))│"
    if show_byte_offsets
        posstr *= "$(lpad(first_byte(node),6)):$(rpad(last_byte(node),6))│"
    end
    val = node.val
    nodestr = haschildren(node) ? "[$(untokenize(head(node)))]" :
    isa(val, Symbol) ? string(val) : repr(val)
    treestr = string(indent, nodestr)
    if node.typ !== nothing
        treestr = string(rpad(treestr, 40), "│$(node.typ)")
    end
    println(io, posstr, treestr)
    if haschildren(node)
        new_indent = indent*"  "
        for n in children(node)
            JuliaSyntax._show_syntax_node(io, current_filename, n, new_indent, show_byte_offsets)
        end
    end
end

## Custom printing via `printstyled`

function Base.printstyled(io::IO, rootnode::MaybeTypedSyntaxNode;
                          type_annotations::Bool=true, iswarn::Bool=true, hide_type_stable::Bool=true,
                          idxend = last_byte(rootnode))
    rt = gettyp(rootnode)
    nd = ndigits(rootnode.source.first_line + nlines(rootnode.source, idxend))
    rootnode = get_function_def(rootnode)
    position = first_byte(rootnode) - 1
    print_linenumber(io, rootnode, position + 1, nd)
    if is_function_def(rootnode)
        # We're printing a MethodInstance
        @assert length(children(rootnode)) == 2
        sig, body = children(rootnode)
        type_annotate, pre, pre2, post = type_annotation_mode(sig, rt; type_annotations, hide_type_stable)
        position = show_src_expr(io, sig, position, pre, pre2; type_annotations, iswarn, hide_type_stable, nd)
        type_annotate && show_annotation(io, rt, post; iswarn)
        rootnode = body
    end
    position = show_src_expr(io, rootnode, position, "", ""; type_annotations, iswarn, hide_type_stable, nd)
    catchup(io, rootnode, position, nd, idxend+1)   # finish the node
    return nothing
end
Base.printstyled(rootnode::MaybeTypedSyntaxNode; kwargs...) = printstyled(stdout, rootnode; kwargs...)

function show_src_expr(io::IO, node::MaybeTypedSyntaxNode, position::Int, pre::String, pre2::String; type_annotations::Bool=true, iswarn::Bool=false, hide_type_stable::Bool=false, nd::Int)
    _lastidx = last_byte(node)
    position = catchup(io, node, position, nd)
    if haschildren(node)
        position = catchup(io, first(children(node)), position, nd)
    end
    print(io, pre)
    for (i, child) in enumerate(children(node))
        i == 2 && print(io, pre2)
        cT = gettyp(child)
        ctype_annotate, cpre, cpre2, cpost = type_annotation_mode(child, cT; type_annotations, hide_type_stable)
        position = show_src_expr(io, child, position, cpre, cpre2; type_annotations, iswarn, hide_type_stable, nd)
        ctype_annotate && show_annotation(io, cT, cpost; iswarn)
    end
    return catchup(io, node, position, nd, _lastidx+1)
end

# should we print a type-annotation?
function is_show_annotation(@nospecialize(T); type_annotations::Bool, hide_type_stable::Bool)
    type_annotations || return false
    if isa(T, Core.Const)
        T = typeof(T.val)
    end
    isa(T, Type) || return false
    hide_type_stable || return true
    return isa(T, Type) && is_type_unstable(T)
end

function type_annotation_mode(node, @nospecialize(T); type_annotations::Bool, hide_type_stable::Bool)
    kind(node) == K"return" && return false, "", "", ""
    type_annotate = is_show_annotation(T; type_annotations, hide_type_stable)
    pre = pre2 = post = ""
    if type_annotate
        if kind(node) ∈ KSet":: where" || is_infix_op_call(node) || (is_prec_assignment(node) && kind(node) != K"=")
            pre, post = "(", ")"
        elseif is_prefix_op_call(node) # insert parens after prefix op and before type-annotating
            pre2, post = "(", ")"
        end
    end
    return type_annotate, pre, pre2, post
end

function show_annotation(io, @nospecialize(T), post=""; iswarn::Bool)
    print(io, post)
    if iswarn
        color = !is_type_unstable(T) ? :cyan :
                 is_small_union_or_tunion(T) ? :yellow : :red
        printstyled(io, "::", T; color)
    else
        printstyled(io, "::", T; color=:cyan)
    end
end

print_linenumber(io::IO, node::MaybeTypedSyntaxNode, position::Int, nd::Int) =
    print_linenumber(io, source_line(node.source, position), nd)
print_linenumber(io::IO, ln::Int, nd::Int) = printstyled(io, lpad(ln, nd), " "; color=:light_black)

# Do any "overdue" printing, generating a line number if needed. Mostly, this catches whitespace.
# Printing occurs over indexes from `position:stop-1`.
function catchup(io::IO, node::MaybeTypedSyntaxNode, position::Int, nd::Int, stop = first_byte(node))
    if position + 1 < stop
        for (i, c) in pairs(node.source[position+1:stop-1])
            print(io, c)
            if c == '\n'
                print_linenumber(io, node, position + i + 1, nd)
            end
        end
        position = stop - 1
    end
    return position
end

nlines(source, idxend) = searchsortedfirst(source.line_starts, idxend)
nlines(source) = length(source.line_starts) - 1

is_type_unstable(@nospecialize(type)) = type isa Type && (!Base.isdispatchelem(type) || type == Core.Box)
function is_small_union_or_tunion(@nospecialize(T))
    Base.isvarargtype(T) && return false
    if T <: Tuple   # is it Tuple{U}
        return all(is_small_union_or_tunion, Base.unwrap_unionall(T).parameters)
    end
    isa(T, Union) || return false
    n, isc = countconcrete(T)
    return isc & (n <= 3)
end

function countconcrete(@nospecialize(T))
    if Base.isdispatchelem(T)
        return 1, true
    elseif isa(T, Union)
        na, isca = countconcrete(T.a)
        nb, iscb = countconcrete(T.b)
        return na + nb, isca & iscb
    end
    return 0, false
end