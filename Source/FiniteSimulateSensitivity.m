function sim = FiniteSimulateSensitivity(m, con, obs, opts)
%FiniteSimulateSensitivitySelect Approximate the sensitivities of every 
%   species with respect to every parameter over all time returns the
%   values at select time points
%
%   Mathematically: dx/dT = (x(T1) - x(T2)) / (T1 - T2)
%   
%   sim = FiniteSimulateSensitivitySelect(m, con, tGet, opts)
%   
%   Inputs
%   m: [ model struct scalar ]
%       The KroneckerBio model that will be simulated
%   con: [ experiment struct vector ]
%       The experimental conditions under which the model will be simulated
%   tGet: [ nonegative vector ]
%       Indicates which time points will be returned. This does not need
%       be sorted. Times larger than con.tF will return NaN for all values.
%   opts: [ options struct scalar {} ]
%       .UseParams [ logical vector nk | positive integer vector {1:nk} ]
%           Indicates the kinetic parameters whose sensitivities are
%           desired
%       .UseSeeds [ logical matrix ns by nCon | logical vector ns |
%                   positive integer vector {[]} ]
%           Indicates the seed parameters whose sensitivities are desired
%       .UseInputControls [ cell vector nCon of logical vectors or positive 
%                           integer vectors | logical vector nq | positive 
%                           integer vector {[]} ]
%           Indicates the input control parameters whose sensitivites are
%           desired
%       .UseDoseControls [ cell vector nCon of logical vectors or positive 
%                           integer vectors | logical vector nq | positive 
%                           integer vector {[]} ]
%           Indicates the dose control parameters whose sensitivites are
%           desired
%       .RelTol [ nonnegative scalar {1e-6} ]
%           Relative tolerance of the integration
%       .AbsTol [ cell vector of nonnegative vectors | nonnegative vector |
%                 nonegative scalar {1e-9} ]
%           Absolute tolerance of the integration. If a cell vector is
%           provided, a different AbsTol will be used for each experiment.
%       .Verbose [ nonnegative integer scalar {1} ]
%           Bigger number displays more progress information
%
%   Outputs
%   sim = FiniteSimulateSensitivitySelect(m, con, tGet, opts)
%   	A vector of structures with each entry being the simulation
%       under one of the conditions.
%       .t tGet
%       .y [ matrix ny by numel(tGet) ]
%           The value of the outputs at each selected time point
%       .x [ matrix nx by numel(tGet) ]
%           The value of the states at each selected time point
%       .dydT [ matrix ny*nT by numel(tGet) ]
%           The value of the sensitivites of the outputs at each selected
%           time point
%       .dxdT [ matrix nx by numel(tGet) ]
%           The value of the sensitivities of the states at each selected
%           time point

% (c) 2015 David R Hagen & Bruce Tidor
% This work is released under the MIT license.

%% Work-up
% Clean up inputs
if nargin < 4
    opts = [];
end

assert(nargin >= 2, 'KroneckerBio:SimulateSensitivity:TooFewInputs', 'SimulateSensitivity requires at least 2 input arguments')
assert(isscalar(m), 'KroneckerBio:SimulateSensitivity:MoreThanOneModel', 'The model structure must be scalar')

% Default options
defaultOpts.Verbose          = 1;

defaultOpts.RelTol           = [];
defaultOpts.AbsTol           = [];

defaultOpts.ComplexStep    = false;

defaultOpts.Normalized       = true;
defaultOpts.UseParams        = 1:m.nk;
defaultOpts.UseSeeds         = [];
defaultOpts.UseInputControls = [];
defaultOpts.UseDoseControls  = [];

opts = mergestruct(defaultOpts, opts);

verbose = logical(opts.Verbose);
opts.Verbose = max(opts.Verbose-1,0);

% Constants
nx = m.nx;
nk = m.nk;
n_con = numel(con);
n_obs = size(obs,1);

% Ensure UseParams is logical vector
[opts.UseParams, nTk] = fixUseParams(opts.UseParams, nk);

% Ensure UseSeeds is a logical matrix
[opts.UseSeeds, nTx] = fixUseSeeds(opts.UseSeeds, nx, n_con);

% Ensure UseControls are cell vectors of logical vectors
[opts.UseInputControls, nTq] = fixUseControls(opts.UseInputControls, n_con, cat(1,con.nq));
[opts.UseDoseControls, nTh] = fixUseControls(opts.UseDoseControls, n_con, cat(1,con.nh));

nT = nTk + nTx + nTq + nTh;

% Refresh conditions
con = refreshCon(m, con);

% RelTol
opts.RelTol = fixRelTol(opts.RelTol);

% Fix AbsTol to be a cell array of vectors appropriate to the problem
opts.AbsTol = fixAbsTol(opts.AbsTol, 2, false(n_con,1), nx, n_con, false, opts.UseParams, opts.UseSeeds, opts.UseInputControls, opts.UseDoseControls);

% Fix observations
obs = fixObservation(con, obs);

%% Run integration for each experiment
sim = emptystruct([n_obs,n_obs], 'Type', 'Name', 't', 'x', 'u', 'y', 'dxdT', 'dudT', 'dydT', 'ie', 'te', 'xe', 'ue', 'ye', 'dxedT', 'duedT', 'dyedT', 'int');

for i_con = 1:n_con
    % Modify opts structure
    opts_i = opts;
    opts_i.AbsTol = opts.AbsTol{i_con};
    opts_i.UseSeeds = opts.UseSeeds(:,i_con);
    opts_i.UseInputControls = opts.UseInputControls{i_con};
    opts_i.UseDoseControls = opts.UseDoseControls{i_con};
    
    % Integrate [x] for each finitely perturbed parameter
    if verbose; fprintf(['Integrating sensitivities for ' con(i_con).Name '...']); end
    ints = integrateAllSens(m, con(i_con), obs(:,i_con), opts_i, true);
    if verbose; fprintf('done.\n'); end
    
    for i_obs = 1:n_obs
        sim(i_obs,i_con) = pastestruct(sim(i_obs), obs(i_obs).Sensitivity(ints(i_obs)));
    end
end
