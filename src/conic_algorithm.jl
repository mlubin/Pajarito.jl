#  Copyright 2016, Los Alamos National Laboratory, LANS LLC, and Chris Coey.
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, you can obtain one at http://mozilla.org/MPL/2.0/.

#=========================================================
This mixed-integer conic programming algorithm is described in:
  Lubin, Yamangil, Bent, Vielma (2016), Extended formulations
  in Mixed-Integer Convex Programming, IPCO 2016, Liege, Belgium
  (available online at http://arxiv.org/abs/1511.06710)

Model MICP with JuMP.jl conic format or Convex.jl DCP format
http://mathprogbasejl.readthedocs.org/en/latest/conic.html


TODO features
- implement warm-starting: use set_best_soln!
- enable querying logs information etc

=========================================================#

using JuMP

type PajaritoConicModel <: MathProgBase.AbstractConicModel
    # Solver parameters
    log_level::Int              # Verbosity flag: -1 for no output, 0 for minimal solution information, 1 for basic OA iteration and solve statistics, 2 for cone summary information, 3 for infeasibilities of duals, cuts, and OA solutions
    timeout::Float64            # Time limit for outer approximation algorithm not including initial load (in seconds)
    rel_gap::Float64            # Relative optimality gap termination condition

    mip_solver_drives::Bool     # Let MIP solver manage convergence and conic subproblem calls (to add lazy cuts and heuristic solutions in branch and cut fashion)
    mip_solver::MathProgBase.AbstractMathProgSolver # MIP solver (MILP or MISOCP)
    mip_subopt_solver::MathProgBase.AbstractMathProgSolver # MIP solver for suboptimal solves, with appropriate options (gap or timeout) specified directly
    mip_subopt_count::Int       # (Conic only) Number of times to solve MIP suboptimally with time limit between zero gap solves
    round_mip_sols::Bool        # (Conic only) Round the integer variable values from the MIP solver before passing to the conic subproblems
    pass_mip_sols::Bool         # (Conic only) Give best feasible solutions constructed from conic subproblem solution to MIP

    cont_solver::MathProgBase.AbstractMathProgSolver # Continuous solver (conic or nonlinear)
    solve_relax::Bool           # (Conic only) Solve the continuous conic relaxation to add initial subproblem cuts
    dualize_relax::Bool         # (Conic only) Solve the conic dual of the continuous conic relaxation
    dualize_sub::Bool           # (Conic only) Solve the conic duals of the continuous conic subproblems

    soc_disagg::Bool            # (Conic only) Disaggregate SOC cones in the MIP only
    soc_in_mip::Bool            # (Conic only) Use SOC cones in the MIP outer approximation model (if MIP solver supports MISOCP)
    psd_eig::Bool               # (Conic SDP only) Use SDP eigenvector-derived cuts
    psd_soc::Bool               # (Conic SDP only) Use SDP eigenvector SOC cuts (if MIP solver supports MISOCP; except during MIP-driven solve)
    init_soc_one::Bool          # (Conic only) Start with disaggregated L_1 outer approximation cuts for SOCs (if soc_disagg)
    init_soc_inf::Bool          # (Conic only) Start with disaggregated L_inf outer approximation cuts for SOCs (if soc_disagg)
    init_exp::Bool              # (Conic Exp only) Start with several outer approximation cuts on the exponential cones
    init_psd_lin::Bool          # (Conic SDP only) Use SDP initial linear cuts
    init_psd_soc::Bool          # (Conic SDP only) Use SDP initial SOC cuts (if MIP solver supports MISOCP)

    viol_cuts_only::Bool        # (Conic only) Only add cuts that are violated by the current MIP solution (may be useful for MSD algorithm where many cuts are added)
    proj_dual_infeas::Bool      # (Conic only) Project dual cone infeasible dual vectors onto dual cone boundaries
    proj_dual_feas::Bool        # (Conic only) Project dual cone strictly feasible dual vectors onto dual cone boundaries
    prim_cuts_only::Bool        # (Conic only) Do not add subproblem cuts
    prim_cuts_always::Bool      # (Conic only) Add primal cuts at each iteration or in each lazy callback
    prim_cuts_assist::Bool      # (Conic only) Add primal cuts only when integer solutions are repeating
    prim_viol_cuts_only::Bool   # (Conic only) Only add primal cuts that are violated (including individual disaggregated cuts)
    prim_max_viol_only::Bool    # (Conic only) Only add primal cuts for the cone with largest absolute violation
    prim_soc_disagg::Bool       # (Conic only) Use disaggregated primal cuts for SOCs
    prim_psd_eig::Bool          # (Conic only) Use eigenvector cuts for SDPs

    tol_zero::Float64           # (Conic only) Tolerance for small epsilons as zeros
    tol_prim_infeas::Float64    # (Conic only) Tolerance level for cone outer infeasibilities for primal cut adding functions (must be at least 1e-5)
    tol_psd_eigvec::Float64     # (Conic SDP only) Tolerance for setting small values in SDP eigenvectors to zeros (for cut sanitation)
    tol_psd_eigval::Float64     # (Conic SDP only) Tolerance for ignoring eigenvectors corresponding to small (positive) eigenvalues

    # Initial data
    num_var_orig::Int           # Initial number of variables
    num_con_orig::Int           # Initial number of constraints
    c_orig                      # Initial objective coefficients vector
    A_orig                      # Initial affine constraint matrix (sparse representation)
    b_orig                      # Initial constraint right hand side
    cone_con_orig               # Initial constraint cones vector (cone, index)
    cone_var_orig               # Initial variable cones vector (cone, index)
    var_types::Vector{Symbol}   # Variable types vector on original variables (only :Bin, :Cont, :Int)
    # var_start::Vector{Float64}  # Variable warm start vector on original variables

    # Conic subproblem data
    cone_con_sub::Vector{Tuple{Symbol,Vector{Int}}} # Constraint cones data in conic subproblem
    cone_var_sub::Vector{Tuple{Symbol,Vector{Int}}} # Variable cones data in conic subproblem
    A_sub_cont::SparseMatrixCSC{Float64,Int64} # Submatrix of A containing full rows and continuous variable columns
    A_sub_int::SparseMatrixCSC{Float64,Int64} # Submatrix of A containing full rows and integer variable columns
    b_sub::Vector{Float64}      # Subvector of b containing full rows
    c_sub_cont::Vector{Float64} # Subvector of c for continuous variables
    c_sub_int::Vector{Float64}  # Subvector of c for integer variables
    b_sub_int::Vector{Float64}  # Slack vector that we operate on in conic subproblem

    # MIP data
    model_mip::JuMP.Model       # JuMP MIP (outer approximation) model
    x_int::Vector{JuMP.Variable} # JuMP (sub)vector of integer variables
    x_cont::Vector{JuMP.Variable} # JuMP (sub)vector of continuous variables

    # SO cone data
    num_soc::Int                # Number of SOCs
    summ_soc::Dict{Symbol,Real} # Data and infeasibilities
    dim_soc::Vector{Int}        # Dimensions
    rows_sub_soc::Vector{Vector{Int}} # Row indices in subproblem
    vars_soc::Vector{Vector{JuMP.Variable}} # Slack variables (newly added or detected)
    vars_dagg_soc::Vector{Vector{JuMP.Variable}} # Disaggregated variables

    # Exp cone data
    num_exp::Int                # Number of ExpPrimal cones
    summ_exp::Dict{Symbol,Real} # Data and infeasibilities
    rows_sub_exp::Vector{Vector{Int}} # Row indices in subproblem
    vars_exp::Vector{Vector{JuMP.Variable}} # Slack variables (newly added or detected)

    # PSD cone data
    num_psd::Int                # Number of SDP cones
    summ_psd::Dict{Symbol,Real} # Data and infeasibilities
    rows_sub_psd::Vector{Vector{Int}} # Row indices in subproblem
    dim_psd::Vector{Int}        # Dimensions
    # vars_svec_psd::Vector{Vector{JuMP.Variable}} # Slack variables in svec form (newly added or detected)
    vars_smat_psd::Vector{Array{JuMP.AffExpr,2}} # Slack variables in smat form (newly added or detected)
    smat_psd::Vector{Array{Float64,2}} # Preallocated matrix to help with memory for SDP cut generation

    # Miscellaneous for algorithms
    update_conicsub::Bool       # Indicates whether to use setbvec! to update an existing conic subproblem model
    model_conic::MathProgBase.AbstractConicModel # Conic subproblem model: persists when the conic solver implements MathProgBase.setbvec!
    oa_started::Bool            # Indicator for Iterative or MIP-solver-driven algorithms started
    new_incumb::Bool            # Indicator for incumbent/best feasible solution not yet added by MIP-solver-driven heuristic callback
    viol_oa::Bool               # Indicator for MIP solution conic infeasibility
    viol_cut::Bool              # Indicator for primal cut added to MIP
    cb_heur                     # Heuristic callback reference (MIP-driven only)
    cb_lazy                     # Lazy callback reference (MIP-driven only)

    # Solve information
    mip_obj::Float64            # Latest MIP (outer approx) objective value
    best_obj::Float64           # Best feasible objective value
    best_int::Vector{Float64}   # Best feasible integer solution
    best_cont::Vector{Float64}  # Best feasible continuous solution
    best_slck::Vector{Float64}  # Best feasible slack vector (for calculating MIP solution)
    gap_rel_opt::Float64        # Relative optimality gap = |mip_obj - best_obj|/|best_obj|
    final_soln::Vector{Float64} # Final solution on original variables
    solve_time::Float64         # Time between starting loadproblem and ending optimize (seconds)

    # Current Pajarito status
    status::Symbol

    # Model constructor
    function PajaritoConicModel(log_level, timeout, rel_gap, mip_solver_drives, mip_solver, mip_subopt_solver, mip_subopt_count, round_mip_sols, pass_mip_sols, cont_solver, solve_relax, dualize_relax, dualize_sub, soc_disagg, soc_in_mip, psd_eig, psd_soc, init_soc_one, init_soc_inf, init_exp, init_psd_lin, init_psd_soc, viol_cuts_only, proj_dual_infeas, proj_dual_feas, prim_cuts_only, prim_cuts_always, prim_cuts_assist, prim_viol_cuts_only, prim_max_viol_only, prim_soc_disagg, prim_psd_eig, tol_zero, tol_prim_infeas, tol_psd_eigvec, tol_psd_eigval)
        # Errors
        if viol_cuts_only && !mip_solver_drives
            # If using iterative algorithm, must always add non-violated cuts
            error("If using Iterative algorithm, cannot add only violated cuts\n")
        end
        if soc_in_mip || init_psd_soc || psd_soc
            # If using MISOCP outer approximation, check MIP solver handles MISOCP
            mip_spec = MathProgBase.supportedcones(mip_solver)
            if !(:SOC in mip_spec)
                error("The MIP solver specified does not support MISOCP\n")
            end
        end
        if prim_cuts_only && !prim_cuts_always
            error("When using primal cuts only, they are also added always (set prim_cuts_always = prim_cuts_assist = true)\n")
        end
        if prim_cuts_always && !prim_cuts_assist
            error("When using primal cuts always, they are also added for assistance (set prim_cuts_assist = true)\n")
        end

        # Warnings
        if log_level > 1
            if !solve_relax
                warn("Not solving the conic continuous relaxation problem; Pajarito may return status :MIPFailure if the outer approximation MIP is unbounded\n")
            end
            if psd_soc && mip_solver_drives
                warn("SOC cuts for SDP cones cannot be added during the MIP-solver-driven algorithm, but initial SOC cuts may be used\n")
            end
            if round_mip_sols
                warn("Integer solutions will be rounded: if this seems to cause numerical challenges, change round_mip_sols option\n")
            end
            if prim_cuts_only
                warn("Using primal cuts only may cause convergence issues\n")
            end
        end

        # Initialize model
        m = new()

        m.log_level = log_level
        m.mip_solver_drives = mip_solver_drives
        m.solve_relax = solve_relax
        m.dualize_relax = dualize_relax
        m.dualize_sub = dualize_sub
        m.pass_mip_sols = pass_mip_sols
        m.round_mip_sols = round_mip_sols
        m.mip_subopt_count = mip_subopt_count
        m.mip_subopt_solver = mip_subopt_solver
        m.soc_in_mip = soc_in_mip
        m.soc_disagg = soc_disagg
        m.init_soc_one = init_soc_one
        m.init_soc_inf = init_soc_inf
        m.init_exp = init_exp
        m.proj_dual_infeas = proj_dual_infeas
        m.proj_dual_feas = proj_dual_feas
        m.viol_cuts_only = viol_cuts_only
        m.mip_solver = mip_solver
        m.cont_solver = cont_solver
        m.timeout = timeout
        m.rel_gap = rel_gap
        m.tol_zero = tol_zero
        m.prim_cuts_only = prim_cuts_only
        m.prim_cuts_always = prim_cuts_always
        m.prim_cuts_assist = prim_cuts_assist
        m.prim_viol_cuts_only = prim_viol_cuts_only
        m.prim_max_viol_only = prim_max_viol_only
        m.prim_soc_disagg = prim_soc_disagg
        m.prim_psd_eig = prim_psd_eig
        m.tol_prim_infeas = tol_prim_infeas
        m.init_psd_lin = init_psd_lin
        m.init_psd_soc = init_psd_soc
        m.psd_eig = psd_eig
        m.psd_soc = psd_soc
        m.tol_psd_eigvec = tol_psd_eigvec
        m.tol_psd_eigval = tol_psd_eigval

        m.var_types = Symbol[]
        # m.var_start = Float64[]
        m.num_var_orig = 0
        m.num_con_orig = 0

        m.update_conicsub = false
        m.oa_started = false
        m.viol_oa = false
        m.viol_cut = false
        m.new_incumb = false

        m.best_obj = Inf
        m.mip_obj = -Inf
        m.gap_rel_opt = NaN
        m.best_int = Float64[]
        m.best_cont = Float64[]
        m.final_soln = Float64[]
        m.solve_time = 0.

        m.status = :NotLoaded

        return m
    end
end

# Used a lot for scaling PSD cone elements (converting between smat and svec)
const sqrt2 = sqrt(2)
const sqrt2inv = 1/sqrt2

#=========================================================
 MathProgBase functions
=========================================================#

# Verify initial conic data and convert appropriate types and store in Pajarito model
function MathProgBase.loadproblem!(m::PajaritoConicModel, c, A, b, cone_con, cone_var)
    # Verify consistency of conic data
    verify_data(c, A, b, cone_con, cone_var)

    # Verify cone compatibility with solver (if solver is not defaultConicsolver: an MPB issue)
    if m.cont_solver != MathProgBase.defaultConicsolver
        # Get cones supported by conic solver
        conic_spec = MathProgBase.supportedcones(m.cont_solver)

        # Pajarito converts rotated SOCs to standard SOCs
        if :SOC in conic_spec
            push!(conic_spec, :SOCRotated)
        end

        # Error if a cone in data is not supported
        for (spec, _) in vcat(cone_con, cone_var)
            if !(spec in conic_spec)
                error("Cones $spec are not supported by the specified conic solver\n")
            end
        end
    end

    # Save original data
    m.num_con_orig = length(b)
    m.num_var_orig = length(c)
    m.c_orig = c
    m.A_orig = A
    m.b_orig = b
    m.cone_con_orig = cone_con
    m.cone_var_orig = cone_var

    m.final_soln = fill(NaN, m.num_var_orig)
    m.status = :Loaded
end

# Store warm-start vector on original variables in Pajarito model
function MathProgBase.setwarmstart!(m::PajaritoConicModel, var_start::Vector{Real})
    error("Warm-starts are not currently implemented in Pajarito (submit an issue)\n")
    # # Check if vector can be loaded
    # if m.status != :Loaded
    #     error("Must specify warm start right after loading problem\n")
    # end
    # if length(var_start) != m.num_var_orig
    #     error("Warm start vector length ($(length(var_start))) does not match number of variables ($(m.num_var_orig))\n")
    # end
    #
    # m.var_start = var_start
end

# Store variable type vector on original variables in Pajarito model
function MathProgBase.setvartype!(m::PajaritoConicModel, var_types::Vector{Symbol})
    if m.status != :Loaded
        error("Must specify variable types right after loading problem\n")
    end
    if length(var_types) != m.num_var_orig
        error("Variable types vector length ($(length(var_types))) does not match number of variables ($(m.num_var_orig))\n")
    end
    if any((var_type -> (var_type != :Bin) && (var_type != :Int) && (var_type != :Cont)), var_types)
        error("Some variable types are not in :Bin, :Int, :Cont\n")
    end
    if !any((var_type -> (var_type == :Bin) || (var_type == :Int)), var_types)
        error("No variables are in :Bin, :Int; use conic solver directly if problem is continuous\n")
    end

    m.var_types = var_types
end

# Solve, given the initial conic model data and the variable types vector and possibly a warm-start vector
function MathProgBase.optimize!(m::PajaritoConicModel)
    if m.status != :Loaded
        error("Must call optimize! function after loading conic data and setting variable types\n")
    end
    if isempty(m.var_types)
        error("Variable types were not specified; must call setvartype! function\n")
    end

    logs = create_logs()
    logs[:total] = time()

    # Transform data
    if m.log_level > 1
        @printf "\nTransforming original data..."
    end
    tic()
    (c_new, A_new, b_new, cone_con_new, cone_var_new, keep_cols, var_types_new) = transform_data(copy(m.c_orig), copy(m.A_orig), copy(m.b_orig), m.cone_con_orig, m.cone_var_orig, m.var_types, m.solve_relax)
    logs[:data_trans] += toq()
    if m.log_level > 1
        @printf "...Done %8.2fs\n" logs[:data_trans]
    end

    # Create conic subproblem data
    if m.log_level > 1
        @printf "\nCreating conic model data..."
    end
    tic()
    (map_rows_sub, cols_cont, cols_int) = create_conicsub_data!(m, c_new, A_new, b_new, cone_con_new, cone_var_new, var_types_new)
    logs[:data_conic] += toq()
    if m.log_level > 1
        @printf "...Done %8.2fs\n" logs[:data_conic]
    end

    # Create MIP model
    if m.log_level > 1
        @printf "\nCreating MIP model..."
    end
    tic()
    (rows_relax_soc, rows_relax_exp, rows_relax_psd) = create_mip_data!(m, c_new, A_new, b_new, cone_con_new, cone_var_new, var_types_new, map_rows_sub, cols_cont, cols_int)
    logs[:data_mip] += toq()
    if m.log_level > 1
        @printf "...Done %8.2fs\n" logs[:data_mip]
    end

    print_cones(m)
    reset_cone_summary!(m)

    if m.solve_relax
        # Solve relaxed conic problem, proceed with algorithm if optimal or suboptimal, else finish
        if m.log_level > 0
            @printf "\nSolving conic relaxation..."
        end
        tic()
        if m.dualize_relax
            solver_relax = ConicDualWrapper(conicsolver=m.cont_solver)
        else
            solver_relax = m.cont_solver
        end
        model_relax = MathProgBase.ConicModel(solver_relax)
        MathProgBase.loadproblem!(model_relax, c_new, A_new, b_new, cone_con_new, cone_var_new)
        MathProgBase.optimize!(model_relax)
        logs[:relax_solve] += toq()
        if m.log_level > 0
            @printf "...Done %8.2fs\n" logs[:relax_solve]
        end

        status_relax = MathProgBase.status(model_relax)
        if status_relax == :Infeasible
            warn("Initial conic relaxation status was $status_relax\n")
            m.status = :Infeasible
        elseif status_relax == :Unbounded
            warn("Initial conic relaxation status was $status_relax\n")
            m.status = :UnboundedRelaxation
        elseif (status_relax != :Optimal) && (status_relax != :Suboptimal)
            warn("Apparent conic solver failure with status $status_relax\n")
        else
            obj_relax = MathProgBase.getobjval(model_relax)
            if m.log_level >= 1
                @printf " - Relaxation status    = %14s\n" status_relax
                @printf " - Relaxation objective = %14.6f\n" obj_relax
            end

            # Optionally rescale dual
            dual = MathProgBase.getdual(model_relax)
            if m.scale_dual_cuts
                # Rescale by number of cones / absval of full conic objective
                scale!(dual, (m.num_soc + m.num_exp + m.num_psd) / (abs(obj_relax) + 1e-5))
            end

            # Add relaxation cuts
            for n in 1:m.num_soc
                add_cut_soc!(m, m.dim_soc[n], m.vars_soc[n], m.vars_dagg_soc[n], dual[m.rows_relax_soc[n]], false, m.summ_soc)
            end
            for n in 1:m.num_exp
                add_cut_exp!(m, m.vars_exp[n], dual[m.rows_relax_exp[n]], false, m.summ_exp)
            end
            for n in 1:m.num_psd
                add_cut_psd!(m, m.dim_psd[n], m.vars_smat_psd[n], dual[m.rows_relax_psd[n]], m.smat_psd[n], false, m.summ_psd)
            end

            print_inf_dual(m)
            # TODO could it ever help to set the conic solution as a (integer-infeasible) warm-start for the MIP solver?
        end

        # Free the conic model
        if applicable(MathProgBase.freemodel!, model_relax)
            MathProgBase.freemodel!(model_relax)
        end
    end

    if (m.status != :Infeasible) && (m.status != :UnboundedRelaxation)
        if !m.prim_cuts_only
            tic()
            if m.log_level > 1
                @printf "\nCreating conic subproblem model..."
            end
            if m.dualize_sub
                solver_conicsub = ConicDualWrapper(conicsolver=m.cont_solver)
            else
                solver_conicsub = m.cont_solver
            end
            m.model_conic = MathProgBase.ConicModel(solver_conicsub)
            if method_exists(MathProgBase.setbvec!, (typeof(m.model_conic), Vector{Float64}))
                # Can use setbvec! on the conic subproblem model: load it
                m.update_conicsub = true
                MathProgBase.loadproblem!(m.model_conic, m.c_sub_cont, m.A_sub_cont, m.b_sub_int, m.cone_con_sub, m.cone_var_sub)
            end
            if m.log_level > 1
                @printf "...Done %8.2fs\n" logs[:conic_proc]
            end
            logs[:conic_proc] += toq()
        end

        # Initialize and begin iterative or MIP-solver-driven algorithm
        logs[:oa_alg] = time()
        m.oa_started = true
        m.best_slck = zeros(length(m.b_sub))

        if m.mip_solver_drives
            if m.log_level > 0
                @printf "\nStarting MIP-solver-driven outer approximation algorithm\n"
            end
            solve_mip_driven!(m, logs)
        else
            if m.log_level > 0
                @printf "\nStarting iterative outer approximation algorithm\n"
            end
            solve_iterative!(m, logs)
        end
        logs[:oa_alg] = time() - logs[:oa_alg]

        if m.best_obj < Inf
            # Have a best feasible solution, update final solution on original variables
            soln_new = zeros(length(c_new))
            soln_new[cols_int] = m.best_int
            soln_new[cols_cont] = m.best_cont
            m.final_soln = zeros(m.num_var_orig)
            m.final_soln[keep_cols] = soln_new
        end
    end

    # Finish timer and print summary
    logs[:total] = time() - logs[:total]
    m.solve_time = logs[:total]
    print_finish(m, logs)
end

MathProgBase.numconstr(m::PajaritoConicModel) = m.num_con_orig

MathProgBase.numvar(m::PajaritoConicModel) = m.num_var_orig

MathProgBase.status(m::PajaritoConicModel) = m.status

MathProgBase.getsolvetime(m::PajaritoConicModel) = m.solve_time

MathProgBase.getobjval(m::PajaritoConicModel) = m.best_obj

MathProgBase.getobjbound(m::PajaritoConicModel) = m.mip_obj

MathProgBase.getsolution(m::PajaritoConicModel) = m.final_soln


#=========================================================
 Data functions
=========================================================#

# Verify consistency of conic data
function verify_data(c, A, b, cone_con, cone_var)
    # Check dimensions of conic problem
    num_con_orig = length(b)
    num_var_orig = length(c)
    if size(A) != (num_con_orig, num_var_orig)
        error("Dimensions of matrix A $(size(A)) do not match lengths of vector b ($(length(b))) and c ($(length(c)))\n")
    end
    if isempty(cone_con) || isempty(cone_var)
        error("Variable or constraint cones are missing\n")
    end

    # Check constraint cones
    inds_con = zeros(Int, num_con_orig)
    for (spec, inds) in cone_con
        if spec == :Free
            error("A cone $spec is in the constraint cones\n")
        end

        if any(inds .> num_con_orig)
            error("Some indices in a constraint cone do not correspond to indices of vector b\n")
        end

        inds_con[inds] += 1
    end
    if any(inds_con .== 0)
        error("Some indices in vector b do not correspond to indices of a constraint cone\n")
    end
    if any(inds_con .> 1)
        error("Some indices in vector b appear in multiple constraint cones\n")
    end

    # Check variable cones
    inds_var = zeros(Int, num_var_orig)
    for (spec, inds) in cone_var
        if any(inds .> num_var_orig)
            error("Some indices in a variable cone do not correspond to indices of vector c\n")
        end

        inds_var[inds] += 1
    end
    if any(inds_var .== 0)
        error("Some indices in vector c do not correspond to indices of a variable cone\n")
    end
    if any(inds_var .> 1)
        error("Some indices in vector c appear in multiple variable cones\n")
    end

    # Verify consistency of cone indices
    for (spec, inds) in vcat(cone_con, cone_var)
        if isempty(inds)
            error("A cone $spec has no associated indices\n")
        end
        if spec == :SOC && (length(inds) < 2)
            error("A cone $spec has fewer than 2 indices ($(length(inds)))\n")
        elseif spec == :SOCRotated && (length(inds) < 3)
            error("A cone $spec has fewer than 3 indices ($(length(inds)))\n")
        elseif spec == :SDP
            if length(inds) < 3
                error("A cone $spec has fewer than 3 indices ($(length(inds)))\n")
            else
                if floor(sqrt(8 * length(inds) + 1)) != sqrt(8 * length(inds) + 1)
                    error("A cone $spec (in SD svec form) does not have a valid (triangular) number of indices ($(length(inds)))\n")
                end
            end
        elseif spec == :ExpPrimal && (length(inds) != 3)
            error("A cone $spec does not have exactly 3 indices ($(length(inds)))\n")
        end
    end
end

# Transform/preprocess data
function transform_data(c_orig, A_orig, b_orig, cone_con_orig, cone_var_orig, var_types, solve_relax)
    A = sparse(A_orig)
    dropzeros!(A)
    (A_I, A_J, A_V) = findnz(A)

    num_con_new = length(b_orig)
    b_new = b_orig
    cone_con_new = Tuple{Symbol,Vector{Int}}[(spec, collect(inds)) for (spec, inds) in cone_con_orig]

    num_var_new = 0
    cone_var_new = Tuple{Symbol,Vector{Int}}[]

    old_new_col = zeros(Int, length(c_orig))
    bin_vars_new = Int[]

    vars_nonneg = Int[]
    vars_nonpos = Int[]
    vars_free = Int[]
    for (spec, cols) in cone_var_orig
        # Ignore zero variable cones
        if spec != :Zero
            vars_nonneg = Int[]
            vars_nonpos = Int[]
            vars_free = Int[]

            for j in cols
                if var_types[j] == :Bin
                    # Put binary vars in NonNeg var cone, unless the original var cone was NonPos in which case the binary vars are fixed at zero
                    if spec != :NonPos
                        num_var_new += 1
                        old_new_col[j] = num_var_new
                        push!(vars_nonneg, j)
                        push!(bin_vars_new, j)
                    end
                else
                    # Put non-binary vars in NonNeg or NonPos or Free var cone
                    num_var_new += 1
                    old_new_col[j] = num_var_new
                    if spec == :NonNeg
                        push!(vars_nonneg, j)
                    elseif spec == :NonPos
                        push!(vars_nonpos, j)
                    else
                        push!(vars_free, j)
                    end
                end
            end

            if !isempty(vars_nonneg)
                push!(cone_var_new, (:NonNeg, old_new_col[vars_nonneg]))
            end
            if !isempty(vars_nonpos)
                push!(cone_var_new, (:NonPos, old_new_col[vars_nonpos]))
            end
            if !isempty(vars_free)
                push!(cone_var_new, (:Free, old_new_col[vars_free]))
            end

            if (spec != :Free) && (spec != :NonNeg) && (spec != :NonPos)
                # Convert nonlinear var cone to constraint cone
                push!(cone_con_new, (spec, collect((num_con_new + 1):(num_con_new + length(cols)))))
                for j in cols
                    num_con_new += 1
                    push!(A_I, num_con_new)
                    push!(A_J, j)
                    push!(A_V, -1.)
                    push!(b_new, 0.)
                end
            end
        end
    end

    A = sparse(A_I, A_J, A_V, num_con_new, length(c_orig))
    keep_cols = find(old_new_col)
    c_new = c_orig[keep_cols]
    A = A[:, keep_cols]
    var_types_new = var_types[keep_cols]

    # Convert SOCRotated cones to SOC cones (MathProgBase definitions)
    # (y,z,x) in RSOC <=> (y+z,-y+z,sqrt2*x) in SOC, y >= 0, z >= 0
    socr_rows = Vector{Int}[]
    for n_cone in 1:length(cone_con_new)
        (spec, rows) = cone_con_new[n_cone]
        if spec == :SOCRotated
            cone_con_new[n_cone] = (:SOC, rows)
            push!(socr_rows, rows)
        end
    end

    (A_I, A_J, A_V) = findnz(A)
    row_to_nzind = map(_ -> Int[], 1:num_con_new)
    for (ind, i) in enumerate(A_I)
        push!(row_to_nzind[i], ind)
    end

    for rows in socr_rows
        inds_1 = row_to_nzind[rows[1]]
        inds_2 = row_to_nzind[rows[2]]

        # Add new constraint cones for y >= 0, z >= 0
        push!(cone_con_new, (:NonNeg, collect((num_con_new + 1):(num_con_new + 2))))

        append!(A_I, fill((num_con_new + 1), length(inds_1)))
        append!(A_J, A_J[inds_1])
        append!(A_V, A_V[inds_1])
        push!(b_new, b_new[rows[1]])

        append!(A_I, fill((num_con_new + 2), length(inds_2)))
        append!(A_J, A_J[inds_2])
        append!(A_V, A_V[inds_2])
        push!(b_new, b_new[rows[2]])

        num_con_new += 2

        # Use old constraint cone SOCRotated for (y+z,-y+z,sqrt2*x) in SOC
        append!(A_I, fill(rows[1], length(inds_2)))
        append!(A_J, A_J[inds_2])
        append!(A_V, A_V[inds_2])
        b_new[rows[1]] += b_new[rows[2]]

        append!(A_I, fill(rows[2], length(inds_1)))
        append!(A_J, A_J[inds_1])
        append!(A_V, -A_V[inds_1])
        b_new[rows[2]] -= b_new[rows[1]]

        for i in rows[3:end]
            for ind in row_to_nzind[i]
                A_V[ind] *= sqrt2
            end
        end
        b_new[rows[2:end]] .*= sqrt2
    end

    if solve_relax
        # Preprocess to tighten bounds on binary and integer variables in conic relaxation
        # Detect isolated row nonzeros with nonzero b
        row_slck_count = zeros(Int, num_con_new)
        for (ind, i) in enumerate(A_I)
            if (A_V[ind] != 0.) && (b_new[i] != 0.)
                if row_slck_count[i] == 0
                    row_slck_count[i] = ind
                elseif row_slck_count[i] > 0
                    row_slck_count[i] = -1
                end
            end
        end

        bin_set_upper = falses(length(bin_vars_new))
        j = 0
        type_j = :Cont
        bound_j = 0.0

        # For each bound-type constraint, tighten by rounding
        for (spec, rows) in cone_con_new
            if (spec != :NonNeg) && (spec != :NonPos)
                continue
            end

            for i in rows
                if row_slck_count[i] > 0
                    # Isolated variable x_j with b_i - a_ij*x_j in spec, b_i & a_ij nonzero
                    j = A_J[row_slck_count[i]]
                    type_j = var_types[keep_cols[j]]
                    bound_j = b_new[i] / A_V[row_slck_count[i]]

                    if (spec == :NonNeg) && (A_V[row_slck_count[i]] > 0) || (spec == :NonPos) && (A_V[row_slck_count[i]] < 0)
                        # Upper bound: b_i/a_ij >= x_j
                        if (type_j == :Bin) && (bound_j >= 1.)
                            # Tighten binary upper bound to 1
                            if spec == :NonNeg
                                # 1 >= x_j
                                b_new[i] = 1.
                                A_V[row_slck_count[i]] = 1.
                            else
                                # -1 <= -x_j
                                b_new[i] = -1.
                                A_V[row_slck_count[i]] = -1.
                            end

                            bin_set_upper[j] = true
                        elseif type_j != :Cont
                            # Tighten binary or integer upper bound by rounding down
                            # TODO this may cause either fixing or infeasibility: detect this and remove variable (at least for binary)
                            if spec == :NonNeg
                                # floor >= x_j
                                b_new[i] = floor(bound_j)
                                A_V[row_slck_count[i]] = 1.
                            else
                                # -floor <= -x_j
                                b_new[i] = -floor(bound_j)
                                A_V[row_slck_count[i]] = -1.
                            end

                            if type_j == :Bin
                                bin_set_upper[j] = true
                            end
                        end
                    else
                        # Lower bound: b_i/a_ij <= x_j
                        if type_j != :Cont
                            # Tighten binary or integer lower bound by rounding up
                            # TODO this may cause either fixing or infeasibility: detect this and remove variable (at least for binary)
                            if spec == :NonPos
                                # ceil <= x_j
                                b_new[i] = ceil(bound_j)
                                A_V[row_slck_count[i]] = 1.
                            else
                                # -ceil >= -x_j
                                b_new[i] = -ceil(bound_j)
                                A_V[row_slck_count[i]] = -1.
                            end
                        end
                    end
                end
            end
        end

        # For any binary variables without upper bound set, add 1 >= x_j to constraint cones
        num_con_prev = num_con_new
        for ind in 1:length(bin_vars_new)
            if !bin_set_upper[ind]
                num_con_new += 1
                push!(A_I, num_con_new)
                push!(A_J, bin_vars_new[ind])
                push!(A_V, 1.)
                push!(b_new, 1.)
            end
        end
        if num_con_new > num_con_prev
            push!(cone_con_new, (:NonNeg, collect((num_con_prev + 1):num_con_new)))
        end
    end

    A_new = sparse(A_I, A_J, A_V, num_con_new, num_var_new)
    dropzeros!(A_new)

    return (c_new, A_new, b_new, cone_con_new, cone_var_new, keep_cols, var_types_new)
end

# Create conic subproblem data
function create_conicsub_data!(m::PajaritoConicModel, c_new::Vector{Float64}, A_new::SparseMatrixCSC{Float64,Int64}, b_new::Vector{Float64}, cone_con_new::Vector{Tuple{Symbol,Vector{Int}}}, cone_var_new::Vector{Tuple{Symbol,Vector{Int}}}, var_types_new::Vector{Symbol})
    # Build new subproblem variable cones by removing integer variables
    cols_cont = Int[]
    cols_int = Int[]
    num_cont = 0
    cone_var_sub = Tuple{Symbol,Vector{Int}}[]

    for (spec, cols) in cone_var_new
        cols_cont_new = Int[]
        for j in cols
            if var_types_new[j] == :Cont
                push!(cols_cont, j)
                num_cont += 1
                push!(cols_cont_new, num_cont)
            else
                push!(cols_int, j)
            end
        end
        if !isempty(cols_cont_new)
            push!(cone_var_sub, (spec, cols_cont_new))
        end
    end

    # Determine "empty" rows with no nonzero coefficients on continuous variables
    (A_cont_I, _, A_cont_V) = findnz(A_new[:, cols_cont])
    num_con_new = size(A_new, 1)
    rows_nz = falses(num_con_new)
    for (i, v) in zip(A_cont_I, A_cont_V)
        if !rows_nz[i] && (v != 0)
            rows_nz[i] = true
        end
    end

    # Build new subproblem constraint cones by removing empty rows
    num_full = 0
    rows_full = Int[]
    cone_con_sub = Tuple{Symbol,Vector{Int}}[]
    map_rows_sub = Vector{Int}(num_con_new)

    for (spec, rows) in cone_con_new
        if (spec == :Zero) || (spec == :NonNeg) || (spec == :NonPos)
            rows_full_new = Int[]
            for i in rows
                if rows_nz[i]
                    push!(rows_full, i)
                    num_full += 1
                    push!(rows_full_new, num_full)
                end
            end
            if !isempty(rows_full_new)
                push!(cone_con_sub, (spec, rows_full_new))
            end
        else
            map_rows_sub[rows] = collect((num_full + 1):(num_full + length(rows)))
            push!(cone_con_sub, (spec, collect((num_full + 1):(num_full + length(rows)))))
            append!(rows_full, rows)
            num_full += length(rows)
        end
    end

    # Store conic data
    m.cone_var_sub = cone_var_sub
    m.cone_con_sub = cone_con_sub

    # Build new subproblem A, b, c data by removing empty rows and integer variables
    m.A_sub_cont = A_new[rows_full, cols_cont]
    m.A_sub_int = A_new[rows_full, cols_int]
    m.b_sub = b_new[rows_full]
    m.c_sub_cont = c_new[cols_cont]
    m.c_sub_int = c_new[cols_int]
    m.b_sub_int = zeros(length(rows_full))

    return (map_rows_sub, cols_cont, cols_int)
end

# Generate MIP model and maps relating conic model and MIP model variables
function create_mip_data!(m::PajaritoConicModel, c_new::Vector{Float64}, A_new::SparseMatrixCSC{Float64,Int64}, b_new::Vector{Float64}, cone_con_new::Vector{Tuple{Symbol,Vector{Int}}}, cone_var_new::Vector{Tuple{Symbol,Vector{Int}}}, var_types_new::Vector{Symbol}, map_rows_sub::Vector{Int}, cols_cont::Vector{Int}, cols_int::Vector{Int})
    # Initialize JuMP model for MIP outer approximation problem
    model_mip = JuMP.Model(solver=m.mip_solver)

    # Create variables and set types
    x_all = @variable(model_mip, [1:length(var_types_new)])
    for j in cols_int
        setcategory(x_all[j], var_types_new[j])
    end

    # Set objective function
    @objective(model_mip, :Min, dot(c_new, x_all))

    # Add variable cones to MIP
    for (spec, cols) in cone_var_new
        if spec == :NonNeg
            for j in cols
                setname(x_all[j], "v$(j)")
                setlowerbound(x_all[j], 0.)
            end
        elseif spec == :NonPos
            for j in cols
                setname(x_all[j], "v$(j)")
                setupperbound(x_all[j], 0.)
            end
        elseif spec == :Free
            for j in cols
                setname(x_all[j], "v$(j)")
            end
        elseif spec == :Zero
            error("Bug: Zero cones should have been removed by transform data function (submit an issue)\n")
        end
    end

    # Loop through nonlinear cones to count and summarize
    num_soc = 0
    num_exp = 0
    num_psd = 0
    summ_soc = Dict{Symbol,Real}(:max_dim => 0, :min_dim => 0)
    summ_exp = Dict{Symbol,Real}(:max_dim => 3, :min_dim => 3)
    summ_psd = Dict{Symbol,Real}(:max_dim => 0, :min_dim => 0)
    temp_psd_smat = Dict{Int,Array{Float64,2}}()

    for (spec, rows) in cone_con_new
        if spec == :SOC
            num_soc += 1
            if summ_soc[:max_dim] < length(rows)
                summ_soc[:max_dim] = length(rows)
            end
            if (summ_soc[:min_dim] == 0) || (summ_soc[:min_dim] > length(rows))
                summ_soc[:min_dim] = length(rows)
            end
        elseif spec == :ExpPrimal
            num_exp += 1
        elseif spec == :SDP
            num_psd += 1
            dim = round(Int, sqrt(1/4 + 2 * length(rows)) - 1/2) # smat space dimension
            if summ_psd[:max_dim] < dim
                summ_psd[:max_dim] = dim
            end
            if (summ_psd[:min_dim] == 0) || (summ_psd[:min_dim] > dim)
                summ_psd[:min_dim] = dim
            end

            # Preallocate smat matrix for SDP cut functions
            if !haskey(temp_psd_smat, dim)
                temp_psd_smat[dim] = Array{Float64,2}(dim, dim)
            end
        end
    end

    # Allocate data for nonlinear cones
    rows_relax_soc = Vector{Vector{Int}}(num_soc)
    rows_sub_soc = Vector{Vector{Int}}(num_soc)
    dim_soc = Vector{Int}(num_soc)
    vars_soc = Vector{Vector{JuMP.AffExpr}}(num_soc)
    vars_dagg_soc = Vector{Vector{JuMP.Variable}}(num_soc)

    rows_relax_exp = Vector{Vector{Int}}(num_exp)
    rows_sub_exp = Vector{Vector{Int}}(num_exp)
    vars_exp = Vector{Vector{JuMP.AffExpr}}(num_exp)

    rows_relax_psd = Vector{Vector{Int}}(num_psd)
    rows_sub_psd = Vector{Vector{Int}}(num_psd)
    dim_psd = Vector{Int}(num_psd)
    # vars_svec_psd = Vector{Vector{JuMP.Variable}}(num_psd)
    vars_smat_psd = Vector{Array{JuMP.AffExpr,2}}(num_psd)
    smat_psd = Vector{Array{Float64,2}}(num_psd)

    # Set up a SOC cone in the MIP
    function add_soc!(n_soc, len, rows, vars)
        if m.soc_in_mip
            # If putting SOCs in the MIP directly, don't need to use other SOC infrastructure in Pajarito so return
            @constraint(model_mip, norm(vars[j] for j in 2:len) <= vars[1])
            return
        end

        dim_soc[n_soc] = len
        rows_relax_soc[n_soc] = rows
        rows_sub_soc[n_soc] = map_rows_sub[rows]
        vars_soc[n_soc] = vars
        vars_dagg_soc[n_soc] = Vector{JuMP.Variable}(0)

        # Set bounds
        @constraint(model_mip, vars[1] >= 0)

        if m.soc_disagg
            # Add disaggregated SOC variables
            # 2*d_j >= y_j^2/x
            vars_dagg = @variable(model_mip, [j in 1:(len - 1)], lowerbound=0.)
            vars_dagg_soc[n_soc] = vars_dagg

            # Add disaggregated SOC constraint
            # x >= sum(2*d_j)
            @constraint(model_mip, 2. * vars[1] >= 4. * sum(vars_dagg))

            # Set names
            for j in 1:(len - 1)
                setname(vars_dagg[j], "d$(j+1)_soc$(n_soc)")
            end




            #TODO add these initial cuts using K* cuts function
            # what about a lifting for abs value





            # Add initial SOC linearizations
            if m.init_soc_one
                # Add initial L_1 SOC cuts
                # 2*d_j >= 2*|y_j|/sqrt(len - 1) - x/(len - 1)
                # for all j, implies x*sqrt(len - 1) >= sum(|y_j|)
                # linearize y_j^2/x at x = 1, y_j = 1/sqrt(len - 1) for all j
                for j in 2:len
                    @constraint(model_mip, 2. * (len - 1) * vars_dagg[j-1] - 2. * sqrt(len - 1) * vars[j] + vars[1] >= 0)
                    @constraint(model_mip, 2. * (len - 1) * vars_dagg[j-1] + 2. * sqrt(len - 1) * vars[j] + vars[1] >= 0)
                end
            end
            if m.init_soc_inf
                # Add initial L_inf SOC cuts
                # 2*d_j >= 2|y_j| - x
                # implies x >= |y_j|, for all j
                # linearize y_j^2/x at x = 1, y_j = 1 for each j (y_k = 0 for k != j)
                # equivalent to standard 3-dim rotated SOC linearizations x + d_j >= 2|y_j|
                for j in 2:len
                    @constraint(model_mip, 2. * (len - 1) * vars_dagg[j-1] - 2. * (len - 1) * vars[j] + (len - 1) * vars[1]) >= 0)
                    @constraint(model_mip, 2. * (len - 1) * vars_dagg[j-1] + 2. * (len - 1) * vars[j] + (len - 1) * vars[1]) >= 0)
                end
            end
        end
    end

    # Set up a ExpPrimal cone in the MIP
    function add_exp!(n_exp, rows, vars)
        rows_relax_exp[n_exp] = rows
        rows_sub_exp[n_exp] = map_rows_sub[rows]
        vars_exp[n_exp] = vars

        # Set bounds
        @constraint(model_mip, vars[2] >= 0)
        @constraint(model_mip, vars[3] >= 0)



        #TODO add these initial cuts using K* cuts function



        # Add initial linearization depending on option
        if m.init_exp
            # TODO maybe pick different linearization points
            # Add initial exp cuts using dual exp cone linearizations
            # Dual exp cone is  e * z >= -x * exp(y / x), z >= 0, x < 0
            # at x = -1; y = -1, -1/2, -1/5, 0, 1/5, 1/2, 1; z = exp(-y) / e = exp(-y - 1)
            for yval in [-1., -0.5, -0.2, 0., 0.2, 0.5, 1.]
                @constraint(model_mip, -vars[1] + yval * vars[2] + exp(-yval - 1.) * vars[3] >= 0)
            end
        end
    end

    # Set up a SDP cone in the MIP
    function add_psd!(n_psd, dim, rows, vars)
        dim_psd[n_psd] = dim
        rows_relax_psd[n_psd] = rows
        rows_sub_psd[n_psd] = map_rows_sub[rows]
        # vars_svec_psd[n_psd] = vars
        smat_psd[n_psd] = temp_psd_smat[dim]
        vars_smat = Array{JuMP.AffExpr,2}(dim, dim)
        vars_smat_psd[n_psd] = vars_smat

        # Set up smat arrays and set bounds
        kSD = 1
        for jSD in 1:dim, iSD in jSD:dim
            if jSD == iSD
                @constraint(model_mip, vars[kSD] >= 0)
                vars_smat[iSD, jSD] = vars[kSD]
            else
                vars_smat[iSD, jSD] = vars_smat[jSD, iSD] = sqrt2inv * vars[kSD]
            end
            kSD += 1
        end



        #TODO add these initial cuts using K* cuts function
        # what about a lifting for abs value


        # Add initial (linear or SOC) SDP outer approximation cuts
        for jSD in 1:dim, iSD in (jSD + 1):dim
            if m.init_psd_soc
                # Add initial rotated SOC for off-diagonal element to enforce 2x2 principal submatrix PSDness
                # Use norm and transformation from RSOC to SOC
                # yz >= ||x||^2, y,z >= 0 <==> norm2(2x, y-z) <= y + z
                @constraint(model_mip, vars_smat[iSD, iSD] + vars_smat[jSD, jSD] >= norm(JuMP.AffExpr[(2. * vars_smat[iSD, jSD]), (vars_smat[iSD, iSD] - vars_smat[jSD, jSD])]))
            elseif m.init_psd_lin
                # Add initial SDP linear cuts based on linearization of 3-dim rotated SOCs that enforce 2x2 principal submatrix PSDness (essentially the dual of SDSOS)
                # 2|m_ij| <= m_ii + m_jj, where m_kk is scaled by sqrt2 in smat space
                @constraint(model_mip, vars_smat[iSD, iSD] + vars_smat[jSD, jSD] >= 2. * vars_smat[iSD, jSD])
                @constraint(model_mip, vars_smat[iSD, iSD] + vars_smat[jSD, jSD] >= -2. * vars_smat[iSD, jSD])
            end
        end
    end

    n_soc = 0
    n_exp = 0
    n_psd = 0
    @expression(model_mip, lhs_expr, b_new - A_new * x_all)

    # Add constraint cones to MIP; if linear, add directly, else create slacks if necessary
    for (spec, rows) in cone_con_new
        if spec == :NonNeg
            @constraint(model_mip, lhs_expr[rows] .>= 0)
        elseif spec == :NonPos
            @constraint(model_mip, lhs_expr[rows] .<= 0.)
        elseif spec == :Zero
            @constraint(model_mip, lhs_expr[rows] .== 0.)
        else
            # Set up nonlinear cone slacks and data
            # vars = @variable(model_mip, [1:length(rows)])
            # @constraint(model_mip, lhs_expr[rows] - vars .== 0.)

            # Set up MIP cones
            if spec == :SOC
                n_soc += 1
                add_soc!(n_soc, length(rows), rows, lhs_expr[rows])
            elseif spec == :ExpPrimal
                n_exp += 1
                add_exp!(n_exp, rows, lhs_expr[rows])
            elseif spec == :SDP
                n_psd += 1
                dim = round(Int, sqrt(1/4 + 2 * length(rows)) - 1/2) # smat space dimension
                add_psd!(n_psd, dim, rows, lhs_expr[rows])
            end
        end
    end

    # Store MIP data
    m.model_mip = model_mip
    m.x_int = x_all[cols_int]
    m.x_cont = x_all[cols_cont]
    # @show model_mip

    # If putting SOCs in the MIP, no SOCs to be dealt with in outer approximation
    if m.soc_in_mip
        num_soc = 0
    end

    m.num_soc = num_soc
    m.summ_soc = summ_soc
    m.dim_soc = dim_soc
    m.rows_sub_soc = rows_sub_soc
    m.vars_soc = vars_soc
    m.vars_dagg_soc = vars_dagg_soc

    m.num_exp = num_exp
    m.summ_exp = summ_exp
    m.rows_sub_exp = rows_sub_exp
    m.vars_exp = vars_exp

    m.num_psd = num_psd
    m.summ_psd = summ_psd
    m.rows_sub_psd = rows_sub_psd
    m.dim_psd = dim_psd
    # m.vars_svec_psd = vars_svec_psd
    m.vars_smat_psd = vars_smat_psd
    m.smat_psd = smat_psd

    return (rows_relax_soc, rows_relax_exp, rows_relax_psd)
end


#=========================================================
 Algorithm functions
=========================================================#

# Solve the MIP model using iterative outer approximation algorithm
function solve_iterative!(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    cache_soln = Set{Vector{Float64}}()
    count_subopt = 0

    while true
        reset_cone_summary!(m)

        if count_subopt < m.mip_subopt_count
            # Solve is a partial solve: use subopt MIP solver, trust that user has provided reasonably small time limit
            setsolver(m.model_mip, m.mip_subopt_solver)
            count_subopt += 1
        else
            # Solve is a full solve: use full MIP solver with remaining time limit
            if isfinite(m.timeout) && applicable(MathProgBase.setparameters!, m.mip_solver)
                MathProgBase.setparameters!(m.mip_solver, TimeLimit=max(0., m.timeout - (time() - logs[:total])))
            end
            setsolver(m.model_mip, m.mip_solver)
            count_subopt = 0
        end

        # Solve MIP
        tic()
        status_mip = solve(m.model_mip)#, suppress_warnings=true)
        logs[:mip_solve] += toq()
        logs[:n_mip] += 1

        if (status_mip == :Infeasible) || (status_mip == :InfeasibleOrUnbounded)
            # Stop if infeasible
            m.status = :Infeasible
            break
        elseif status_mip == :Unbounded
            # Stop if unbounded (initial conic relax solve should detect this)
            if m.solve_relax
                warn("MIP solver returned status $status_mip, which suggests that the initial subproblem cuts added were too weak\n")
            else
                warn("MIP solver returned status $status_mip, because the initial conic relaxation was not solved\n")
            end
            m.status = :CutsFailure
            break
        elseif (status_mip == :UserLimit) || (status_mip == :Optimal)
            # Update OA bound if MIP bound is better than current OA bound
            mip_obj_bound = MathProgBase.getobjbound(m.model_mip)
            if mip_obj_bound > m.mip_obj
                m.mip_obj = mip_obj_bound

                # Calculate relative outer approximation gap, finish if satisfy optimality gap condition
                m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
                print_gap(m, logs)
                if m.gap_rel_opt < m.rel_gap
                    m.status = :Optimal
                    break
                end
            end

            # Timeout if MIP reached time limit
            if status_mip == :UserLimit && ((time() - logs[:total]) > (m.timeout - 0.01))
                m.status = :UserLimit
                break
            end
        else
            warn("MIP solver returned status $status_mip, which Pajarito does not handle (please submit an issue)\n")
            m.status = :MIPFailure
            break
        end

        # Get current integer solution, if any NaNs, proceed to next optimal solve
        soln_int = getvalue(m.x_int)
        if any(isnan, soln_int)
            count_subopt = m.mip_subopt_count
            warn("Solution has NaN values, proceeding to next optimal MIP solve\n")
            continue
        end
        if m.round_mip_sols
            # Round the integer values
            soln_int = map!(round, soln_int)
        end

        # Add subproblem cuts on new integer solutions, check convergence on old integer solutions
        is_repeat = false
        if soln_int in cache_soln
            # Integer solution has been seen before
            logs[:n_repeat] += 1

            if count_subopt == 0
                # Solve was optimal solve but we have not converged, must try primal cuts
                warn("Integer solution has repeated but optimality gap condition is not satisfied\n")
                is_repeat = true
            end

            # Add primal cuts and make next solve optimal
            count_subopt = m.mip_subopt_count
        else
            # Integer solution is new: solve new conic subproblem, update incumbent solution if feasible
            push!(cache_soln, soln_int)
            dual = solve_conicsub!(m, soln_int, logs)

            # If have a new incumbent, calculate relative outer approximation gap, finish if satisfy optimality gap condition
            if m.new_incumb
                # Calculate relative outer approximation gap, finish if satisfy optimality gap condition
                m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
                print_gap(m, logs)
                if m.gap_rel_opt < m.rel_gap
                    m.status = :Optimal
                    break
                end
            end

            # If have a dual and we are using subproblem cuts, add subproblem cuts
            if !m.prim_cuts_only && !isempty(dual)
                add_subp_cuts!(m, dual)
            end
        end

        if m.prim_cuts_always || (!m.is_viol_subp && m.prim_cuts_assist)
            # Add primal cuts if using always or if no violated subproblem cuts were added and using primal cuts assist
            add_prim_cuts!(m)

            if !m.is_infeas
                # MIP solver solution is conic-feasible, check if it is a new incumbent
                soln_cont = getvalue(m.x_cont)
                obj_full = dot(m.c_sub_int, soln_int) + dot(m.c_sub_cont, soln_cont)

                if obj_full < m.best_obj
                    # Save new incumbent info
                    m.best_obj = obj_full
                    m.best_int = soln_int
                    m.best_cont = soln_cont

                    # Calculate relative outer approximation gap, finish if satisfy optimality gap condition
                    m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
                    print_gap(m, logs)
                    if m.gap_rel_opt < m.rel_gap
                        m.status = :Optimal
                        break
                    end
                end
            elseif is_repeat && !m.is_viol_prim
                # Repeated solution is conic infeasible but no violated cuts have been added, fail
                warn("No violated subproblem cuts or primal cuts could be added on conic-infeasible OA solution (this should not happen: please submit an issue)\n")
                m.status = :CutsFailure
                break
            end
        elseif is_repeat && !m.prim_cuts_assist
            # Repeated integer solution and no primal cuts, so fail
            warn("No violated subproblem cuts could be added, and primal cuts are turned off (try using prim_cuts_assist = true)\n")
            m.status = :CutsFailure
            break
        end

        # Finish if exceeded timeout option
        if (time() - logs[:oa_alg]) > m.timeout
            m.status = :UserLimit
            break
        end

        # Give the best feasible solution to the MIP as a warm-start
        # TODO use this at start when enable warm-starting Pajarito
        if m.pass_mip_sols && m.new_incumb
            set_best_soln!(m, logs)
        end
    end
end

# Solve the MIP model using MIP-solver-driven callback algorithm
function solve_mip_driven!(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    if isfinite(m.timeout) && applicable(MathProgBase.setparameters!, m.mip_solver)
        MathProgBase.setparameters!(m.mip_solver, TimeLimit=max(0., m.timeout - (time() - logs[:total])))
        setsolver(m.model_mip, m.mip_solver)
    end

    cache_soln = Set{Vector{Float64}}()

    # Add lazy cuts callback to add dual and primal conic cuts
    function callback_lazy(cb)
        m.cb_lazy = cb
        reset_cone_summary!(m)

        # Get current integer solution
        soln_int = getvalue(m.x_int)
        if m.round_mip_sols
            # Round the integer values
            soln_int = map!(round, soln_int)
        end

        if soln_int in cache_soln
            # Integer solution has been seen before
            logs[:n_repeat] += 1
        else
            # Integer solution is new: solve new conic subproblem, update incumbent solution if feasible
            push!(cache_soln, soln_int)
            dual = solve_conicsub!(m, soln_int, logs)

            # If we have a dual and we are using subproblem cuts, add subproblem cuts
            if !m.prim_cuts_only && !isempty(dual)
                add_subp_cuts!(m, dual)
            end
        end

        if m.is_viol_subp && !m.prim_cuts_always
            # Violated subproblem cut was added and not using primal cuts always, so return
            return
        end

        if !m.prim_cuts_assist
            # Not using primal cuts, so fail
            # (Don't have to fail if conic feasible, but for the sake of code simplicity, just make the user turn on primal cuts)
            warn("No violated subproblem cuts could be added, and primal cuts are turned off (try using prim_cuts_assist = true)\n")
            m.status = :CutsFailure
            return JuMP.StopTheSolver
        end

        # Try to add violated primal cuts, finish if any violated cuts have been added or if solution is conic feasible
        add_prim_cuts!(m)
        if !m.is_infeas || m.is_viol_subp || m.is_viol_prim
            return
        end

        # No violated cuts could be added on conic infeasible solution: fail
        # (Don't need to fail if solution doesn't improve MIP's best solution value, but this is probably rare or impossible depending on MIP solver behavior)
        warn("No violated subproblem cuts or primal cuts could be added on conic-infeasible OA solution (this should not happen: please submit an issue)\n")
        m.status = :CutsFailure
        return JuMP.StopTheSolver
    end
    addlazycallback(m.model_mip, callback_lazy)

    if m.pass_mip_sols
        # Add heuristic callback to give MIP solver feasible solutions from conic solves
        function callback_heur(cb)
            # If have a new best feasible solution since last heuristic solution added, set MIP solution to the new best feasible solution
            if m.new_incumb
                m.cb_heur = cb
                set_best_soln!(m, logs)
                addsolution(cb)
                m.new_incumb = false
            end
        end
        addheuristiccallback(m.model_mip, callback_heur)
    end

    # Start MIP solver
    logs[:mip_solve] = time()
    status_mip = solve(m.model_mip)#, suppress_warnings=true)
    logs[:mip_solve] = time() - logs[:mip_solve]

    if (status_mip == :Infeasible) || (status_mip == :InfeasibleOrUnbounded)
        m.status = :Infeasible
        return
    elseif status_mip == :Unbounded
        if m.solve_relax
            warn("MIP solver returned status $status_mip, which suggests that the initial subproblem cuts added were too weak\n")
        else
            warn("MIP solver returned status $status_mip, because the initial conic relaxation was not solved\n")
        end
        m.status = :CutsFailure
        return
    elseif status_mip == :UserLimit
        # Either a timeout, or a cuts failure terminated the MIP solver
        m.mip_obj = getobjbound(m.model_mip)
        if isfinite(m.best_obj)
            # We have a feasible solution
            m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
        end
        if m.status != :CutsFailure
            m.status = status_mip
        end
        return
    elseif status_mip == :Optimal
        # Check if conic solver solution (if exists) satisfies gap condition, if so, use that solution, else use MIP solver's solution
        # (Since we didn't stop the MIP solver due to cuts failure, the MIP solution should be conic feasible)
        m.mip_obj = getobjbound(m.model_mip)
        if isfinite(m.best_obj)
            # We have a feasible solution from conic solver
            m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
            if m.gap_rel_opt < m.rel_gap
                # Solution satisfies gap
                m.status = :Optimal
                return
            end
        end

        # Use MIP solver's solution
        m.best_int = getvalue(m.x_int)
        m.best_cont = getvalue(m.x_cont)
        m.best_obj = dot(m.c_sub_int, m.best_int) + dot(m.c_sub_cont, m.best_cont)
        m.gap_rel_opt = (m.best_obj - m.mip_obj) / (abs(m.best_obj) + 1e-5)
        if m.gap_rel_opt < m.rel_gap
            m.status = :Optimal
        else
            m.status = :Suboptimal
        end
        return
    else
        warn("MIP solver returned status $status_mip, which Pajarito does not handle (please submit an issue)\n")
        m.status = :MIPFailure
        return
    end
end

# Solve conic subproblem given some solution to the integer variables, update incumbent
function solve_conicsub!(m::PajaritoConicModel, soln_int::Vector{Float64}, logs::Dict{Symbol,Real})
    # Calculate new b vector from integer solution and solve conic model
    m.b_sub_int = m.b_sub - m.A_sub_int*soln_int

    # Load/solve conic model
    tic()
    if m.update_conicsub
        # Reuse model already created by changing b vector
        MathProgBase.setbvec!(m.model_conic, m.b_sub_int)
    else
        # Load new model
        if m.dualize_sub
            solver_conicsub = ConicDualWrapper(conicsolver=m.cont_solver)
        else
            solver_conicsub = m.cont_solver
        end

        m.model_conic = MathProgBase.ConicModel(solver_conicsub)
        MathProgBase.loadproblem!(m.model_conic, m.c_sub_cont, m.A_sub_cont, m.b_sub_int, m.cone_con_sub, m.cone_var_sub)
    end

    MathProgBase.optimize!(m.model_conic)
    logs[:n_conic] += 1
    logs[:conic_solve] += toq()

    status_conic = MathProgBase.status(m.model_conic)
    if status_conic == :Optimal
        logs[:n_opt] += 1
    elseif status_conic == :Infeasible
        logs[:n_inf] += 1
    elseif status_conic == :Suboptimal
        logs[:n_sub] += 1
    elseif status_conic == :UserLimit
        logs[:n_lim] += 1
    elseif status_conic == :ConicFailure
        logs[:n_fail] += 1
    else
        logs[:n_other] += 1
    end

    if (status_conic == :Optimal) || (status_conic == :Suboptimal)
        # Get solution and calculate objective for full problem
        soln_cont = MathProgBase.getsolution(m.model_conic)
        obj_full = dot(m.c_sub_int, soln_int) + dot(m.c_sub_cont, soln_cont)

        # If optimal, solution is feasible: check if have new best feasible solution
        # TODO if suboptimal, solution could still be feasible (status is not well defined): check feas
        if status_conic == :Optimal
            logs[:n_feas] += 1

            if obj_full < m.best_obj
                # Save new incumbent info and indicate new solution for heuristic callback
                m.best_obj = obj_full
                m.best_int = soln_int
                m.best_cont = soln_cont
                m.best_slck = m.b_sub_int - m.A_sub_cont * m.best_cont
                m.new_incumb = true
            end
        end

        # Optionally rescale dual so that cuts will be satisfied with MIP solver linear tolerances
        dual_conic = MathProgBase.getdual(m.model_conic)
        if m.scale_dual_cuts
            # Rescale by number of cones / absval of full conic objective
            scale!(dual_conic, (m.num_soc + m.num_exp + m.num_psd) / (abs(obj_full) + 1e-5))
        end
    elseif status_conic == :Infeasible
        # Optionally rescale infeasible ray so that infeasible point will be cut off with MIP solver linear tolerances
        dual_conic = MathProgBase.getdual(m.model_conic)
        ray_value = vecdot(dual_conic, m.b_sub_int)
        if ray_value > -m.tol_zero
            warn("Serious conic solver failure: returned status $status_conic but b'y is not sufficiently negative for infeasible ray y (this should not happen: please submit an issue)\n")
            dual_conic = Float64[]
        elseif m.scale_dual_cuts
            # Rescale by number of cones / value of ray
            scale!(dual_conic, (m.num_soc + m.num_exp + m.num_psd) / ray_value)
        end
    else
        warn("Conic solver failure: returned status $status_conic\n")
        dual_conic = Float64[]
    end

    # Free the conic model if not saving it
    if !m.update_conicsub && applicable(MathProgBase.freemodel!, m.model_conic)
        MathProgBase.freemodel!(m.model_conic)
    end

    return dual_conic
end

# Construct and warm-start MIP solution using best solution
function set_best_soln!(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    tic()
    set_soln!(m, m.x_int, m.best_int)
    set_soln!(m, m.x_cont, m.best_cont)

    for n in 1:m.num_soc
        set_soln!(m, m.vars_soc[n], m.best_slck, m.rows_sub_soc[n])
        if m.soc_disagg
            set_dagg_soln!(m, m.vars_dagg_soc[n], m.best_slck, m.rows_sub_soc[n])
        end
    end
    # for n in 1:m.num_exp
    #     set_soln!(m, m.vars_exp[n], m.best_slck, m.rows_sub_exp[n])
    # end
    # for n in 1:m.num_psd
    #     set_soln!(m, m.vars_svec_psd[n], m.best_slck, m.rows_sub_psd[n])
    # end
    logs[:conic_soln] += toq()
end

# Call setvalue or setsolutionvalue solution for a vector of variables and a solution vector and corresponding solution indices
function set_soln!(m::PajaritoConicModel, vars::Vector{JuMP.Variable}, soln::Vector{Float64}, inds::Vector{Int})
    if m.mip_solver_drives && m.oa_started
        for (j, ind) in enumerate(inds)
            setsolutionvalue(m.cb_heur, vars[j], soln[ind])
        end
    else
        for (j, ind) in enumerate(inds)
            setvalue(vars[j], soln[ind])
        end
    end
end

# Call setvalue or setsolutionvalue solution for a vector of variables and a solution vector
function set_soln!(m::PajaritoConicModel, vars::Vector{JuMP.Variable}, soln::Vector{Float64})
    if m.mip_solver_drives && m.oa_started
        for j in 1:length(vars)
            setsolutionvalue(m.cb_heur, vars[j], soln[j])
        end
    else
        for j in 1:length(vars)
            setvalue(vars[j], soln[j])
        end
    end
end

# Call setvalue or setsolutionvalue solution for a vector of SOC disaggregated variables and a solution vector and corresponding solution indices
function set_dagg_soln!(m::PajaritoConicModel, vars_dagg::Vector{JuMP.Variable}, soln::Vector{Float64}, inds)
    if m.mip_solver_drives && m.oa_started
        if soln[inds[1]] == 0.
            for j in 2:length(inds)
                setsolutionvalue(m.cb_heur, vars_dagg[j-1], 0.)
            end
        else
            for j in 2:length(inds)
                setsolutionvalue(m.cb_heur, vars_dagg[j-1], (soln[inds[j]]^2 / (2. * soln[inds[1]])))
            end
        end
    else
        if soln[inds[1]] == 0.
            for j in 2:length(inds)
                setvalue(vars_dagg[j-1], 0.)
            end
        else
            for j in 2:length(inds)
                setvalue(vars_dagg[j-1], (soln[inds[j]]^2 / (2. * soln[inds[1]])))
            end
        end
    end
end

# Transform svec vector into symmetric smat matrix
function make_smat!(svec::Vector{Float64}, smat::Array{Float64,2}, dim::Int)
    kSD = 1
    for jSD in 1:dim, iSD in jSD:dim
        if jSD == iSD
            smat[iSD, jSD] = svec[kSD]
        else
            smat[iSD, jSD] = smat[jSD, iSD] = sqrt2inv * svec[kSD]
        end
        kSD += 1
    end
    return smat
end


#=========================================================
 K^* cuts functions
=========================================================#

function add_subp_cuts!(m, dual)
    m.is_viol_subp = false

    for n in 1:m.num_soc
        # Project onto dual cone
        # y' = ||x'||
        cut[1] = vecnorm(cut[j] for j in 2:dim)

        add_cut_soc!(m, m.dim_soc[n], m.vars_soc[n], m.vars_dagg_soc[n], dual[m.rows_soc[n]], m.summ_soc)
    end
    for n in 1:m.num_exp


        add_cut_exp!(m, m.vars_exp[n], dual[m.rows_exp[n]], m.summ_exp)
    end
    for n in 1:m.num_psd


        add_cut_psd!(m, m.dim_psd[n], m.vars_smat_psd[n], dual[m.rows_psd[n]], m.smat_psd[n], m.summ_psd)
    end
    return is_viol_subp
end

function add_prim_cuts!(m)
    m.is_infeas = m.is_viol_prim = false

    for n in 1:m.num_soc
        # getvalue on cone
        # pass in (1, w/||w||) as dual

        add_cut_soc!(m, m.dim_soc[n], m.vars_soc[n], m.vars_dagg_soc[n], dual[m.rows_soc[n]], m.summ_soc)

    end
    for n in 1:m.num_exp


        add_cut_exp!(m, m.vars_exp[n], dual[m.rows_exp[n]], m.summ_exp)

    end
    for n in 1:m.num_psd


        add_cut_psd!(m, m.dim_psd[n], m.vars_smat_psd[n], dual[m.rows_psd[n]], m.smat_psd[n], m.summ_psd)
    end
    return (is_infeas, is_viol_prim)
end

function add_cut_soc!(m, disagg, dim, vars, vars_dagg, cut, summary)
    # Remove near-zeros, discard if all values are small
    keep = false
    for j in 1:dim
        if abs(cut[j]) < m.tol_zero
            cut[j] = 0.
        else
            keep = true
        end
    end
    if !keep
        continue
    end

    # Add disagg cuts
    add_full = false
    if disagg
        for j in 2:dim
            if cut[j] == 0.
                # Zero cut
                continue
            elseif (dim - 1) * cut[j]^2 / cut[1] < m.tol_zero
                # Coefficient is too small
                add_full = true
                continue
            elseif (cut[j] / cut[1])^2 < 1e-5
                # Cut is poorly conditioned, add it but also add full cut
                add_full = true
            end

            # (x'_j)^2/||x'||*y + 2*||x'||*d_j + 2*x'_j*x_j >= 0
            # Scale up by number of cuts (dim - 1) to achieve linear tolerances
            @expression(m.model_mip, cut_expr, (dim - 1) * (cut[j]^2 / cut[1] * vars[1] + 2 * cut[1] * vars_dagg[j-1] + 2 * cut[j] * vars[j]))
            add_cut!(m, cut_expr, is_viol, summary)
        end
    end

    # Add full cut
    if add_full || !disagg
        # ||x'||*y + dot(x', x) >= 0
        @expression(m.model_mip, cut_expr, vecdot(cut, vars))
        add_cut!(m, cut_expr, is_viol, summary)
    end
end


function add_cut_exp!(m, vars, cut, is_viol, summary)
    nothing
end


function add_cut_psd!(m, dim, vars, cut, smat, is_viol, summary)
    nothing
end


function add_cut!(m, cut_expr, is_viol, summary)
    if !m.oa_started
        @constraint(m.model_mip, cut_expr >= 0)
    elseif -getvalue(cut_expr) > m.tol_prim_infeas
        update_inf_cut!(m, cut_expr, spec_summ)

        if m.mip_solver_drives
            @lazyconstraint(m.cb_lazy, cut_expr >= 0)
        else
            @constraint(m.model_mip, cut_expr >= 0)
        end

        is_viol = true
    elseif !m.viol_cuts_only
        update_inf_cut!(m, cut_expr, spec_summ)

        if m.mip_solver_drives
            @lazyconstraint(m.cb_lazy, cut_expr >= 0)
        else
            @constraint(m.model_mip, cut_expr >= 0)
        end
    end
end

# Update cut infeasibility values in cone summary
function update_inf_cut!(m::PajaritoConicModel, cut_expr::JuMP.AffExpr, summary::Dict{Symbol,Real})

    # add count cuts...




    if (m.log_level <= 2) || !m.oa_started
        return
    end

    inf_cut = -getvalue(cut_expr)
    if inf_cut > 0.
        summary[:cut_max_n] += 1
        summary[:cut_max] = max(inf_cut, summary[:cut_max])
    elseif inf_cut < 0.
        summary[:cut_min_n] += 1
        summary[:cut_min] = max(-inf_cut, summary[:cut_min])
    end
end




# # Add dual cut for a ExpPrimal cone
# function add_dual_cuts_exp!(m::PajaritoConicModel, vars::Vector{JuMP.Variable}, dual::Vector{Float64}, spec_summ::Dict{Symbol,Real})
#     # 0 Rescale by largest absolute value or discard if near zero
#     if maxabs(dual) > m.tol_zero
#         scale!(dual, (1. / maxabs(dual)))
#     else
#         return
#     end
#
#     # 1 Calculate dual inf using exp space definition of dual cone as e * dual[3] >= -dual[1] * exp(dual[2] / dual[1])
#     if dual[1] == 0.
#         if (dual[2] >= 0) && (dual[3] >= 0)
#             inf_dual = -max(dual[2], dual[3])
#         elseif (dual[2] < 0.) || (dual[3] < 0.)
#             inf_dual = max(-dual[2], -dual[3])
#         end
#     elseif dual[1] > 0.
#         inf_dual = dual[1]
#     elseif dual[3] < 0.
#         inf_dual = -dual[3]
#     else
#         inf_dual = -dual[1] * exp(dual[2] / dual[1]) - e * dual[3]
#     end
#     update_inf_dual!(m, inf_dual, spec_summ)
#
#     # 2 Sanitize: remove near-zeros
#     for ind in 1:3
#         if abs(dual[ind]) < m.tol_zero
#             dual[ind]
#         end
#     end
#
#     # 2 Project dual if infeasible and proj_dual_infeas or if strictly feasible and proj_dual_feas
#     if ((inf_dual > 0.) && m.proj_dual_infeas) || ((inf_dual < 0.) && m.proj_dual_feas)
#         # Projection: epigraph variable equals LHS
#         dual[3] = -dual[1] * exp(dual[2] / dual[1] - 1.)
#     end
#
#     # Discard cut if dual[1] >= 0 (simply enforces the nonnegativity of x[2] and x[3]) or dual[3] < 0 (can't project onto dual[3] = 0)
#     if (dual[1] >= 0) || (dual[3] < 0.)
#         return
#     end
#
#     # 3 Add 3-dim cut
#     @expression(m.model_mip, cut_expr, sum(dual[j] * vars[j] for j in 1:3))
#     if !m.viol_cuts_only || !m.oa_started || (-getvalue(cut_expr) > m.tol_zero)
#         if m.mip_solver_drives && m.oa_started
#             @lazyconstraint(m.cb_lazy, cut_expr >= 0)
#         else
#             @constraint(m.model_mip, cut_expr >= 0)
#         end
#         update_inf_cut!(m, cut_expr, spec_summ)
#     end
# end
#
# # Add cuts from dual for a SDP cone
# function add_dual_cuts_psd!(m::PajaritoConicModel, dim::Int, vars_smat::Array{JuMP.AffExpr,2}, dual::Vector{Float64}, smat::Array{Float64,2}, spec_summ::Dict{Symbol,Real})
#     # 0 Rescale by largest absolute value or discard if near zero
#     if maxabs(dual) > m.tol_zero
#         scale!(dual, (1. / maxabs(dual)))
#     else
#         return
#     end
#
#     # Convert dual to smat space and store in preallocated smat matrix
#     make_smat!(dual, smat, dim)
#
#     # Get eigendecomposition of smat dual (use symmetric property), save eigenvectors in smat matrix
#     (eigvals, _) = LAPACK.syev!('V', 'L', smat)
#
#     # 1 Calculate dual inf as negative minimum eigenvalue
#     inf_dual = -minimum(eigvals)
#     update_inf_dual!(m, inf_dual, spec_summ)
#
#     # Discard cut if largest eigenvalue is too small
#     if maximum(eigvals) <= m.tol_psd_eigval
#         return
#     end
#
#     # 2 Project dual if infeasible and proj_dual_infeas, create cut expression
#     if (inf_dual > 0.) && m.proj_dual_infeas
#         @expression(m.model_mip, cut_expr, sum(eigvals[v] * smat[vi, v] * smat[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim, v in 1:dim if eigvals[v] > 0.))
#     else
#         @expression(m.model_mip, cut_expr, sum(eigvals[v] * smat[vi, v] * smat[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim, v in 1:dim if eigvals[v] != 0.))
#     end
#
#     # 3 Add super-rank linear dual cut
#     if !m.viol_cuts_only || !m.oa_started || (-getvalue(cut_expr) > m.tol_zero)
#         if m.mip_solver_drives && m.oa_started
#             @lazyconstraint(m.cb_lazy, cut_expr >= 0)
#         else
#             @constraint(m.model_mip, cut_expr >= 0)
#         end
#         update_inf_cut!(m, cut_expr, spec_summ)
#     end
#
#     if !m.psd_eig
#         return
#     end
#
#     # 3 For each (significant) eigenvector, add SDP OA cuts: SOC or linear
#     if m.psd_soc && !(m.oa_started && m.mip_solver_drives)
#         soln_smat = similar(smat)
#         for j in 1:dim, i in j:dim
#             soln_smat[i, j] = soln_smat[j, i] = getvalue(vars_smat[i, j])
#         end
#         vvT_soln = similar(smat)
#         vec_expr = Vector{JuMP.AffExpr}(dim)
#
#         for v in 1:dim
#             if eigvals[v] <= m.tol_psd_eigval
#                 continue
#             end
#
#             # Add one SDP SOC eigenvector cut (derived from Schur complement)
#             # Calculate most violated cut over all dim possible cuts (one per diagonal element)
#             vvT_soln = eigvals[v] * (smat[:, v] * smat[:, v]') .* soln_smat
#             val_min = Inf
#             ind_min = 0
#             for iSD in 1:dim
#                 # TODO Check this
#                 val_cur = soln_smat[iSD, iSD] * sum(vvT_soln[k, l] for k in 1:dim, l in 1:dim if (k != iSD && l != iSD)) - 2 * sumabs2(vvT_soln[k, iSD] for k in 1:dim if (k != iSD))
#                 if val_cur < val_min
#                     val_min = val_cur
#                     ind_min = iSD
#                 end
#             end
#
#             # Use norm and transformation from RSOC to SOC
#             # yz >= ||x||^2, y,z >= 0 <==> norm2(2x, y-z) <= y + z
#             @expression(m.model_mip, z_expr, sum(eigvals[v] * smat[k, v] * smat[l, v] * vars_smat[k, l] for k in 1:dim, l in 1:dim if (k != ind_min && l != ind_min)))
#             @expression(m.model_mip, cut_expr, vars_smat[ind_min, ind_min] + z_expr - norm(((k == ind_min) ? (vars_smat[ind_min, ind_min] - z_expr) : (2 * eigvals[v] * smat[k, ind_min] * smat[k, v] * vars_smat[k, ind_min])) for k in 1:dim))
#
#             if !m.viol_cuts_only || !m.oa_started || (-getvalue(cut_expr) > m.tol_zero)
#                 if m.mip_solver_drives && m.oa_started
#                     @lazyconstraint(m.cb_lazy, cut_expr >= 0)
#                 else
#                     @constraint(m.model_mip, cut_expr >= 0)
#                 end
#                 update_inf_cut!(m, cut_expr, spec_summ)
#             end
#         end
#     else
#         for v in 1:dim
#             if eigvals[v] <= m.tol_psd_eigval
#                 continue
#             end
#
#             # Add non-sparse rank-1 cut from smat eigenvector v
#             @expression(m.model_mip, cut_expr, sum(eigvals[v] * smat[vi, v] * smat[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim))
#             if !m.viol_cuts_only || !m.oa_started || (-getvalue(cut_expr) > m.tol_zero)
#                 if m.mip_solver_drives && m.oa_started
#                     @lazyconstraint(m.cb_lazy, cut_expr >= 0)
#                 else
#                     @constraint(m.model_mip, cut_expr >= 0)
#                 end
#                 update_inf_cut!(m, cut_expr, spec_summ)
#             end
#
#             # Sanitize eigenvector v for sparser rank-1 cut and add sparse rank-1 cut from smat sparsified eigenvector v
#             for vi in 1:dim
#                 if abs(smat[vi, v]) < m.tol_psd_eigvec
#                     smat[vi, v] = 0.
#                 end
#             end
#             @expression(m.model_mip, cut_expr, sum(eigvals[v] * smat[vi, v] * smat[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim))
#             if !m.viol_cuts_only || !m.oa_started || (-getvalue(cut_expr) > m.tol_zero)
#                 if m.mip_solver_drives && m.oa_started
#                     @lazyconstraint(m.cb_lazy, cut_expr >= 0)
#                 else
#                     @constraint(m.model_mip, cut_expr >= 0)
#                 end
#                 update_inf_cut!(m, cut_expr, spec_summ)
#             end
#         end
#     end
# end



#=========================================================
 Primal cuts functions
=========================================================#

# For each cone, calc outer inf and add if necessary, add primal cuts violated by current MIP solution
function calc_outer_inf_cuts!(m::PajaritoConicModel, add_viol_cuts::Bool, logs::Dict{Symbol,Real})
    tic()
    m.viol_oa = false
    m.viol_cut = false

    max_inf = 0.
    max_n = 0
    for n in 1:m.num_soc
        # Calculate and update outer infeasibility
        vars = m.vars_soc[n]
        inf_outer = vecnorm(getvalue(vars[j]) for j in 2:length(vars)) - getvalue(vars[1])
        update_inf_outer!(m, inf_outer, m.summ_soc)
        if inf_outer < m.tol_prim_infeas
            continue
        end
        m.viol_oa = true
        if !add_viol_cuts
            continue
        end

        # If adding all viol cuts, add, else record largest violation seen
        if !m.prim_max_viol_only
            add_prim_cuts_soc!(m, m.dim_soc[n], vars, m.vars_dagg_soc[n])
        elseif inf_outer > max_inf
            max_inf = inf_outer
            max_n = n
        end
    end
    if m.prim_max_viol_only && (max_n > 0)
        add_prim_cuts_soc!(m, m.dim_soc[max_n], m.vars_soc[max_n], m.vars_dagg_soc[max_n])
    end

    max_inf = 0.
    max_n = 0
    for n in 1:m.num_exp
        vars = m.vars_exp[n]
        inf_outer = getvalue(vars[2]) * exp(getvalue(vars[1]) / (getvalue(vars[2]))) - getvalue(vars[3])
        update_inf_outer!(m, inf_outer, m.summ_exp)
        if inf_outer < m.tol_prim_infeas
            continue
        end
        m.viol_oa = true
        if !add_viol_cuts
            continue
        end

        # If adding all viol cuts, add, else record largest violation seen
        if !m.prim_max_viol_only
            add_prim_cuts_exp!(m, vars)
        elseif inf_outer > max_inf
            max_inf = inf_outer
            max_n = n
        end
    end
    if m.prim_max_viol_only && (max_n > 0)
        add_prim_cuts_exp!(m, m.vars_exp[max_n])
    end

    max_inf = 0.
    max_n = 0
    max_eig = Vector{Float64}()
    for n in 1:m.num_psd
        # Convert solution to lower smat space and store in preallocated smat matrix
        vars_smat = m.vars_smat_psd[n]
        smat = m.smat_psd[n]
        dim = m.dim_psd[n]
        for j in 1:dim, i in j:dim
            smat[i, j] = getvalue(vars_smat[i, j])
        end

        # Get eigendecomposition of smat solution (use symmetric property), save eigenvectors in smat matrix, rescale eigenvalues
        (eigvals, _) = LAPACK.syev!('V', 'L', smat)
        inf_outer = -minimum(eigvals)
        update_inf_outer!(m, inf_outer, m.summ_psd)
        if inf_outer < m.tol_prim_infeas
            continue
        end
        m.viol_oa = true
        if !add_viol_cuts
            continue
        end

        # If adding all viol cuts, add, else record largest violation seen
        if !m.prim_max_viol_only
            add_prim_cuts_psd!(m, dim, vars_smat, smat, eigvals)
        elseif inf_outer > max_inf
            max_inf = inf_outer
            max_n = n
            max_eig = eigvals
        end
    end
    if m.prim_max_viol_only && (max_n > 0)
        add_prim_cuts_psd!(m, m.dim_psd[max_n], m.vars_smat_psd[max_n], m.smat_psd[max_n], eigvals)
    end

    logs[:outer_inf] += toq()
end

# Add primal cuts for a SOC
function add_prim_cuts_soc!(m::PajaritoConicModel, dim::Int, vars::Vector{JuMP.Variable}, vars_dagg::Vector{JuMP.Variable})
    prim = getvalue(vars)

    # Rescale by largest absolute value or discard if near zero
    if maxabs(prim) > m.tol_zero
        scale!(prim, (1. / maxabs(prim)))
    else
        return
    end

    if m.prim_soc_disagg
        # Discard if epigraph variable is small
        if prim[1] <= m.tol_zero
            return
        end

        for j in 2:dim
            # Discard if primal variable is small
            if prim[j] == 0.
                continue
            end

            # Add disagg primal cut (divide by original epigraph variable)
            # 2*dj >= 2xj`/y`*xj - (xj'/y`)^2*y
            @expression(m.model_mip, cut_expr, (prim[j] / prim[1])^2 * vars[1] + 2. * vars_dagg[j-1] - (2 * prim[j] / prim[1]) * vars[j])
            if !m.prim_viol_cuts_only || (-getvalue(cut_expr) > m.tol_zero)
                if m.mip_solver_drives
                    @lazyconstraint(m.cb_lazy, cut_expr >= 0)
                else
                    @constraint(m.model_mip, cut_expr >= 0)
                end
                m.viol_cut = true
            end
        end
    else
        # Sanitize: remove near-zeros
        for ind in 1:dim
            if abs(prim[ind]) < m.tol_zero
                prim[ind] = 0.
            end
        end

        # Discard if norm of non-epigraph variables is zero
        solnorm = vecnorm(prim[j] for j in 2:dim)
        if solnorm <= m.tol_zero
            return
        end

        # Add full primal cut
        # x`*x / ||x`|| <= y
        @expression(m.model_mip, cut_expr, vars[1] - sum(prim[j] / solnorm * vars[j] for j in 2:dim))
        if !m.prim_viol_cuts_only || (-getvalue(cut_expr) > m.tol_zero)
            if m.mip_solver_drives
                @lazyconstraint(m.cb_lazy, cut_expr >= 0)
            else
                @constraint(m.model_mip, cut_expr >= 0)
            end
            m.viol_cut = true
        end
    end
end

# Add primal cut for a ExpPrimal cone
function add_prim_cuts_exp!(m::PajaritoConicModel, vars::Vector{JuMP.Variable})
    prim = getvalue(vars)

    # 0 Rescale by largest absolute value or discard if near zero
    if maxabs(prim) > m.tol_zero
        scale!(prim, (1. / maxabs(prim)))
    else
        return
    end

    # Discard if perspective variable is zero
    if prim[2] <= m.tol_zero
        return
    end

    # Add primal cut
    # y`e^(x`/y`) + e^(x`/y`)*(x-x`) + (e^(x`/y`)(y`-x`)/y`)*(y-y`) = e^(x`/y`)*(x + (y`-x`)/y`*y) = e^(x`/y`)*(x+(1-x`/y`)*y) <= z
    @expression(m.model_mip, cut_expr, vars[3] - exp(prim[1] / prim[2]) * (vars[1] + (1. - prim[1] / prim[2]) * vars[2]))
    if !m.prim_viol_cuts_only || (-getvalue(cut_expr) > m.tol_zero)
        if m.mip_solver_drives
            @lazyconstraint(m.cb_lazy, cut_expr >= 0)
        else
            @constraint(m.model_mip, cut_expr >= 0)
        end
        m.viol_cut = true
    end
end

# Add primal cuts for a SDP cone
function add_prim_cuts_psd!(m::PajaritoConicModel, dim::Int, vars_smat::Array{JuMP.AffExpr,2}, prim::Array{Float64,2}, eigvals::Vector{Float64})
    # 0 Rescale smat and eigvals by largest absolute value or discard if near zero
    if (maxabs(prim) > m.tol_zero) && (maxabs(eigvals) > m.tol_zero)
        scale!(prim, (1. / maxabs(prim)))
        scale!(eigvals, (1. / maxabs(eigvals)))
    else
        return
    end

    for j in 1:dim, i in j:dim
        if abs(prim[i, j]) < m.tol_zero
            prim[i, j] = 0.
        end
    end

    if !m.prim_psd_eig
        # Add super-rank linear primal cut
        @expression(m.model_mip, cut_expr, sum(-eigvals[v] * prim[vi, v] * prim[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim, v in 1:dim if eigvals[v] < 0.))
        if !m.prim_viol_cuts_only || (-getvalue(cut_expr) > m.tol_zero)
            if m.mip_solver_drives
                @lazyconstraint(m.cb_lazy, cut_expr >= 0)
            else
                @constraint(m.model_mip, cut_expr >= 0)
            end
            m.viol_cut = true
        end
    else
        for v in 1:dim
            if -eigvals[v] <= m.tol_psd_eigval
                continue
            end

            # Add non-sparse rank-1 cut from smat eigenvector v
            @expression(m.model_mip, cut_expr, sum(-eigvals[v] * prim[vi, v] * prim[vj, v] * vars_smat[vi, vj] for vj in 1:dim, vi in 1:dim))
            if !m.prim_viol_cuts_only || (-getvalue(cut_expr) > m.tol_zero)
                if m.mip_solver_drives
                    @lazyconstraint(m.cb_lazy, cut_expr >= 0)
                else
                    @constraint(m.model_mip, cut_expr >= 0)
                end
                m.viol_cut = true
            end
        end
    end
end

# Update outer approximation infeasibility values in cone summary
function update_inf_outer!(m::PajaritoConicModel, inf_outer::Float64, spec_summ::Dict{Symbol,Real})
    if m.log_level <= 2
        return
    end

    if inf_outer > 0.
        spec_summ[:outer_max_n] += 1
        spec_summ[:outer_max] = max(inf_outer, spec_summ[:outer_max])
    elseif inf_outer < 0.
        spec_summ[:outer_min_n] += 1
        spec_summ[:outer_min] = max(-inf_outer, spec_summ[:outer_min])
    end
end


#=========================================================
 Logging and printing functions
=========================================================#

# Reset all summary values for all cones in preparation for next iteration
function reset_cone_summary!(m::PajaritoConicModel)
    if m.log_level <= 2
        return
    end

    if m.num_soc > 0
        m.summ_soc[:outer_max_n] = 0
        m.summ_soc[:outer_max] = 0.
        m.summ_soc[:outer_min_n] = 0
        m.summ_soc[:outer_min] = 0.
        m.summ_soc[:dual_max_n] = 0
        m.summ_soc[:dual_max] = 0.
        m.summ_soc[:dual_min_n] = 0
        m.summ_soc[:dual_min] = 0.
        m.summ_soc[:cut_max_n] = 0
        m.summ_soc[:cut_max] = 0.
        m.summ_soc[:cut_min_n] = 0
        m.summ_soc[:cut_min] = 0.
    end

    if m.num_exp > 0
        m.summ_exp[:outer_max_n] = 0
        m.summ_exp[:outer_max] = 0.
        m.summ_exp[:outer_min_n] = 0
        m.summ_exp[:outer_min] = 0.
        m.summ_exp[:dual_max_n] = 0
        m.summ_exp[:dual_max] = 0.
        m.summ_exp[:dual_min_n] = 0
        m.summ_exp[:dual_min] = 0.
        m.summ_exp[:cut_max_n] = 0
        m.summ_exp[:cut_max] = 0.
        m.summ_exp[:cut_min_n] = 0
        m.summ_exp[:cut_min] = 0.
    end

    if m.num_psd > 0
        m.summ_psd[:outer_max_n] = 0
        m.summ_psd[:outer_max] = 0.
        m.summ_psd[:outer_min_n] = 0
        m.summ_psd[:outer_min] = 0.
        m.summ_psd[:dual_max_n] = 0
        m.summ_psd[:dual_max] = 0.
        m.summ_psd[:dual_min_n] = 0
        m.summ_psd[:dual_min] = 0.
        m.summ_psd[:cut_max_n] = 0
        m.summ_psd[:cut_max] = 0.
        m.summ_psd[:cut_min_n] = 0
        m.summ_psd[:cut_min] = 0.
    end
end

# Create dictionary of logs for timing and iteration counts
function create_logs()
    logs = Dict{Symbol,Real}()

    # Timers
    logs[:total] = 0.       # Performing total optimize algorithm
    logs[:data_trans] = 0.  # Transforming data
    logs[:data_conic] = 0.  # Generating conic data
    logs[:data_mip] = 0.    # Generating MIP data
    logs[:relax_solve] = 0. # Solving initial conic relaxation model
    logs[:oa_alg] = 0.      # Performing outer approximation algorithm
    logs[:mip_solve] = 0.   # Solving the MIP model
    logs[:conic_proc] = 0.  # Processing conic b vector and dual and solution
    logs[:conic_solve] = 0. # Solving conic subproblem model
    logs[:conic_soln] = 0.  # Adding new feasible conic solution
    logs[:dual_cuts] = 0.   # Adding subproblem cuts
    logs[:outer_inf] = 0.   # Calculating outer inf and adding primal cuts

    # Counters
    logs[:n_conic] = 0      # Number of conic subproblem solves
    logs[:n_mip] = 0        # Number of MIP solves for iterative
    logs[:n_feas] = 0       # Number of feasible solutions encountered
    logs[:n_repeat] = 0     # Number of times integer solution repeats

    return logs
end

# Print cone dimensions summary
function print_cones(m::PajaritoConicModel)
    if m.log_level <= 1
        return
    end

    @printf "\nCone types summary:"
    @printf "\n%-10s | %-8s | %-8s | %-8s\n" "Cone" "Count" "Min dim" "Max dim"
    if m.num_soc > 0
        @printf "%10s | %8d | %8d | %8d\n" "SOC" m.num_soc m.summ_soc[:min_dim] m.summ_soc[:max_dim]
    end
    if m.num_exp > 0
        @printf "%10s | %8d | %8d | %8d\n" "ExpPrimal" m.num_exp 3 3
    end
    if m.num_psd > 0
        @printf "%10s | %8d | %8d | %8d\n" "SDP" m.num_psd m.summ_psd[:min_dim] m.summ_psd[:max_dim]
    end
    flush(STDOUT)
end

# Print dual cone infeasibilities of dual vectors only
function print_inf_dual(m::PajaritoConicModel)
    if m.log_level <= 2
        return
    end

    @printf "\nInitial subproblem cuts summary:"
    @printf "\n%-10s | %-32s\n" "Cone" "Dual cone infeas"
    @printf "%-10s | %-6s %-8s  %-6s %-8s\n" "" "Infeas" "Worst" "Feas" "Worst"
    if m.num_soc > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "SOC" m.summ_soc[:dual_max_n] m.summ_soc[:dual_max] m.summ_soc[:dual_min_n] m.summ_soc[:dual_min]
    end
    if m.num_exp > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "ExpPrimal" m.summ_exp[:dual_max_n] m.summ_exp[:dual_max] m.summ_exp[:dual_min_n] m.summ_exp[:dual_min]
    end
    if m.num_psd > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "SDP" m.summ_psd[:dual_max_n] m.summ_psd[:dual_max] m.summ_psd[:dual_min_n] m.summ_psd[:dual_min]
    end
    flush(STDOUT)
end

# Print infeasibilities of dual vectors and subproblem cuts added to MIP
function print_inf_dualcuts(m::PajaritoConicModel)
    if m.log_level <= 2
        return
    end

    @printf "\n%-10s | %-32s | %-32s\n" "Cone" "Dual cone infeas" "Cut infeas"
    @printf "%-10s | %-6s %-8s  %-6s %-8s | %-6s %-8s  %-6s %-8s\n" "" "Infeas" "Worst" "Feas" "Worst" "Infeas" "Worst" "Feas" "Worst"
    if m.num_soc > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e | %5d  %8.2e  %5d  %8.2e\n" "SOC" m.summ_soc[:dual_max_n] m.summ_soc[:dual_max] m.summ_soc[:dual_min_n] m.summ_soc[:dual_min] m.summ_soc[:cut_max_n] m.summ_soc[:cut_max] m.summ_soc[:cut_min_n] m.summ_soc[:cut_min]
    end
    if m.num_exp > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e | %5d  %8.2e  %5d  %8.2e\n" "ExpPrimal" m.summ_exp[:dual_max_n] m.summ_exp[:dual_max] m.summ_exp[:dual_min_n] m.summ_exp[:dual_min] m.summ_exp[:cut_max_n] m.summ_exp[:cut_max] m.summ_exp[:cut_min_n] m.summ_exp[:cut_min]
    end
    if m.num_psd > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e | %5d  %8.2e  %5d  %8.2e\n" "SDP" m.summ_psd[:dual_max_n] m.summ_psd[:dual_max] m.summ_psd[:dual_min_n] m.summ_psd[:dual_min] m.summ_psd[:cut_max_n] m.summ_psd[:cut_max] m.summ_psd[:cut_min_n] m.summ_psd[:cut_min]
    end
    flush(STDOUT)
end

# Print outer approximation infeasibilities of MIP solution
function print_inf_outer(m::PajaritoConicModel)
    if m.log_level <= 2
        return
    end

    @printf "\n%-10s | %-32s\n" "Cone" "Outer approx infeas"
    @printf "%-10s | %-6s %-8s  %-6s %-8s\n" "" "Infeas" "Worst" "Feas" "Worst"
    if m.num_soc > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "SOC" m.summ_soc[:outer_max_n] m.summ_soc[:outer_max] m.summ_soc[:outer_min_n] m.summ_soc[:outer_min]
    end
    if m.num_exp > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "ExpPrimal" m.summ_exp[:outer_max_n] m.summ_exp[:outer_max] m.summ_exp[:outer_min_n] m.summ_exp[:outer_min]
    end
    if m.num_psd > 0
        @printf "%10s | %5d  %8.2e  %5d  %8.2e\n" "SDP" m.summ_psd[:outer_max_n] m.summ_psd[:outer_max] m.summ_psd[:outer_min_n] m.summ_psd[:outer_min]
    end
    flush(STDOUT)
end

# Print objective gap information for iterative
function print_gap(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    if m.log_level <= 1
        return
    end

    if (logs[:n_mip] == 1) || (m.log_level > 2)
        @printf "\n%-4s | %-14s | %-14s | %-11s | %-11s\n" "Iter" "Best obj" "OA obj" "Rel gap" "Time (s)"
    end
    if m.gap_rel_opt < 1000
        @printf "%4d | %+14.6e | %+14.6e | %11.3e | %11.3e\n" logs[:n_mip] m.best_obj m.mip_obj m.gap_rel_opt (time() - logs[:oa_alg])
    elseif isnan(m.gap_rel_opt)
        @printf "%4d | %+14.6e | %+14.6e | %11s | %11.3e\n" logs[:n_mip] m.best_obj m.mip_obj "Inf" (time() - logs[:oa_alg])
    else
        @printf "%4d | %+14.6e | %+14.6e | %11s | %11.3e\n" logs[:n_mip] m.best_obj m.mip_obj ">1000" (time() - logs[:oa_alg])
    end
    flush(STDOUT)
end

# Print objective gap information for MSD
function print_gap_MSD(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    if m.log_level <= 2
        return
    end

    if logs[:n_mip] == 0
        @printf "\n%-14s | %-14s | %-11s | %-11s\n" "Best obj" "OA obj" "Rel gap" "Time (s)"
        logs[:n_mip] += 1
    end
    if m.gap_rel_opt < 1000
        @printf "%+14.6e | %+14.6e | %11.3e | %11.3e\n" m.best_obj m.mip_obj m.gap_rel_opt (time() - logs[:oa_alg])
    elseif isnan(m.gap_rel_opt)
        @printf "%+14.6e | %+14.6e | %11s | %11.3e\n" m.best_obj m.mip_obj "Inf" (time() - logs[:oa_alg])
    else
        @printf "%+14.6e | %+14.6e | %11s | %11.3e\n" m.best_obj m.mip_obj ">1000" (time() - logs[:oa_alg])
    end
    flush(STDOUT)
end

# Print after finish
function print_finish(m::PajaritoConicModel, logs::Dict{Symbol,Real})
    if m.log_level < 0
        flush(STDOUT)
        return
    end

    @printf "\nPajarito MICP solve summary:\n"
    @printf " - Total time (s)       = %14.2e\n" logs[:total]
    @printf " - Status               = %14s\n" m.status
    @printf " - Best feasible obj.   = %+14.6e\n" m.best_obj
    @printf " - Final OA obj. bound  = %+14.6e\n" m.mip_obj
    @printf " - Relative opt. gap    = %14.3e\n" m.gap_rel_opt

    if m.log_level == 0
        @printf "\n"
        flush(STDOUT)
        return
    end

    if !m.mip_solver_drives
        @printf " - MIP solve count      = %14d\n" logs[:n_mip]
    end
    @printf " - Conic solve count    = %14d\n" logs[:n_conic]
    @printf " - Feas. solution count = %14d\n" logs[:n_feas]
    @printf " - Integer repeat count = %14d\n" logs[:n_repeat]
    @printf "\nTimers (s):\n"
    @printf " - Setup                = %14.2e\n" (logs[:total] - logs[:oa_alg])
    @printf " -- Transform data      = %14.2e\n" logs[:data_trans]
    @printf " -- Create conic data   = %14.2e\n" logs[:data_conic]
    @printf " -- Create MIP data     = %14.2e\n" logs[:data_mip]
    @printf " -- Load/solve relax    = %14.2e\n" logs[:relax_solve]
    if m.mip_solver_drives
        @printf " - MIP-driven algorithm = %14.2e\n" logs[:oa_alg]
    else
        @printf " - Iterative algorithm  = %14.2e\n" logs[:oa_alg]
        @printf " -- Solve MIPs          = %14.2e\n" logs[:mip_solve]
    end
    @printf " -- Solve conic model   = %14.2e\n" logs[:conic_solve]
    @printf " -- Process conic data  = %14.2e\n" logs[:conic_proc]
    @printf " -- Add conic solution  = %14.2e\n" logs[:conic_soln]
    @printf " -- Add cuts from dual       = %14.2e\n" logs[:dual_cuts]
    @printf " -- Use outer inf/cuts  = %14.2e\n" logs[:outer_inf]
    @printf "\n"
    flush(STDOUT)
end
