include("./Notebook.jl")
include("./ExploreExpression.jl")


module ModuleManager
    workspace_count = 0

    get_workspace(id=workspace_count) = Core.eval(ModuleManager, Symbol("workspace", id))

    function make_workspace()
        global workspace_count += 1
        # TODO: define `expr` directly, but it's more readable right now
        code = "module workspace$(workspace_count) end"
        expr = Meta.parse(code)
        Core.eval(ModuleManager, expr)
    end
    make_workspace() # so that there's immediately something to work with

    forbiddenmoves = [:eval, :include, Symbol("#eval"), Symbol("include")]

    function move_vars(from_index::Integer, to_index::Integer, to_delete::Set{Symbol}=Set{Symbol}())
        old_workspace = get_workspace(from_index)
        new_workspace = get_workspace(to_index)
        Core.eval(new_workspace, Meta.parse("import ..workspace$(from_index)"))

        for symbol in names(old_workspace, all=true, imported=true)
            if !(symbol in forbiddenmoves) && symbol != Symbol("workspace",from_index - 1) && symbol != Symbol("workspace",from_index)
                if symbol in to_delete
                    Core.eval(old_workspace, Meta.parse("$symbol = nothing"))
                else
                    Core.eval(new_workspace, Meta.parse("$symbol = workspace$(from_index).$symbol"))
                end
            end
        end
    end

    function delete_vars(to_delete::Set{Symbol}=Set{Symbol}())
        if !isempty(to_delete)
            from = workspace_count
            make_workspace()
            move_vars(from, from+1, to_delete)
        end
    end
end


"Run a cell and all the cells that depend on it"
function run_reactive(notebook::Notebook, cell::Cell)
    if cell.parsedcode === nothing
        cell.parsedcode = Meta.parse(cell.code, raise=false)
    end

    old_modified = cell.modified_symbols
    old_dependent, _ = dependent_cells(notebook, cell)

    symstate = ExploreExpression.compute_symbolreferences(cell.parsedcode)
    cell.referenced_symbols = symstate.references
    cell.modified_symbols = symstate.assignments

    # TODO: assert that cell doesn't modify variables which are modified by other cells

    new_dependent, cyclic = dependent_cells(notebook, cell)
    will_update = union(old_dependent, new_dependent)

    union(old_modified, [c.modified_symbols for c in will_update]...) |>
    ModuleManager.delete_vars

    run_single.(setdiff(will_update, cyclic))
    show_error.(cyclic, "Cyclic reference")

    return will_update
end


function run_single(cell::Cell)
    if isa(cell.parsedcode, Expr) && cell.parsedcode.head == :using
        # Don't run this cell. We set its output directly and stop the method prematurely.
        show_error(cell, "Use `import` instead of `using`.\nSupport for `using` will be added soon.")
        return
    end

    try
        show_output(cell, Core.eval(ModuleManager.get_workspace(), cell.parsedcode))
        # TODO: capture stdout and display it somehwere, but let's keep using the actual terminal for now
    catch err
        show_error(cell, err)
    end
end


"Cells to be evaluated in a single reactive cell run, in order - including the given cell"
function dependent_cells(notebook::Notebook, root::Cell)
    entries = Cell[]
    exits = Cell[]
    cyclic = Set{Cell}()

    function dfs(cell::Cell)
        if cell in exits
            return
        elseif cell in entries
            detected_cycle = entries[findfirst(entries .== [cell]):end]
            cyclic = union(cyclic, detected_cycle)
            return
        end

        push!(entries, cell)
        dfs.(directly_dependent_cells(notebook, cell.modified_symbols))
        push!(exits, cell)
    end

    dfs(root)
    return reverse(exits), cyclic
end


"Return cells that reference any of the given symbols - does *not* recurse"
function directly_dependent_cells(notebook::Notebook, symbols::Set{Symbol})
    return filter(notebook.cells) do cell
        return any(s in symbols for s in cell.referenced_symbols)
    end
end