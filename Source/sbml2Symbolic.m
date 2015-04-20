function symModel = sbml2Symbolic(sbmlModel, opts)
%SBML2SYMBOLIC Inport SBML model and covert to kroneckerbio symbolic model.
%   Detailed explanation goes here
% Currently based heavily on simbio2Symbolic (which MathWorks clearly adpated the libSBML API)
% Note: Doesn't convert variable names in Part 2, assuming that SBML IDs
%   are all allowed symbolic variable names.
%   Uses IDs as the internal identifier in this function.

% TEST: convert SBML -> SimBio -> symbolic for comparison; remove when done
% When done, deprecate the sbmlimport function (it depends on the SimBiology toolbox)
% symbolicTest = simbio2Symbolic(sbmlimport(sbmlModel));

%% Options
% Resolve missing inputs
if nargin < 2
    opts = [];
end

% Options for displaying progress
defaultOpts.Verbose = 0;
defaultOpts.Validate = false;
defaultOpts.UseNames = false;

opts = mergestruct(defaultOpts, opts);

verbose = logical(opts.Verbose);
opts.Verbose = max(opts.Verbose-1,0);

%% Call libSBML to import SBML model
if verbose; fprintf('Convert SBML model using libSBML...\n'); end

sbml = TranslateSBML(sbmlModel, double(opts.Validate), opts.Verbose);

if verbose; fprintf('done.\n'); end

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 1: Extracting the Model Variables %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Note: In SBML, `id` is a required globally scoped reference while `name`
% is an optional human readable identifier. This function uses ids throughout for
% parsing/converting and outputs ids by default. You can specify that ids
% be converted to names with the option ConvertIDs. However, this may
% introduce ambiguity and/or errors if names aren't valid Matlab strings or
% breaks scoping rules that I don't know about.
if verbose; fprintf('Extracting model components...'); end

%% Model name
if ~isempty(sbml.name) % In this case, name is more useful if present
    name = sbml.name;
elseif ~isempty(sbml.id)
    name = sbml.id;
else
    name = 'Inported SBML model';
end

%% Compartments
nv = length(sbml.compartment);
vIDs   = cell(nv,1);
vNames = cell(nv,1);
v      = zeros(nv,1);
dv     = zeros(nv,1);

for i = 1:nv
    vIDs{i}   = sbml.compartment(i).id;
    vNames{i} = sbml.compartment(i).name;
    
    if sbml.compartment(i).isSetSize
        v(i) = sbml.compartment(i).size;
    else
        % TODO: Consider variable compartment size by assignment or fitting
        warning('Warning:sbml2Symbolic:CompartmetSizeNotSet: Compartment size not set, setting default size = 1.')
        v(i) = 1;
    end
    
    dv(i) = sbml.compartment(i).spatialDimensions;
    
end

%% Species
nxu = length(sbml.species);
xuIDs   = cell(nxu,1);
xuNames = cell(nxu,1);
xu0     = zeros(nxu,1);
vxuInd  = zeros(nxu,1);
isu     = false(nxu,1);
xuSubstanceUnits = false(nxu,1);

for i = 1:nxu
    species = sbml.species(i);
    
    xuIDs{i}   = species.id;
    xuNames{i} = species.name;
    
    if species.isSetInitialAmount
        xu0(i) = species.initialAmount;
    elseif species.isSetInitialConcentration
        xu0(i) = species.initialConcentration;
    else
        warning('sbml2Symbolic:InitialConcentrationNotSet: Initial species conc. not set for %s, setting default conc. = 0.', xuIDs{i})
        xu0(i) = 0;
    end
    
    % Get species compartment by id
    vxuInd(i) = find(strcmp(species.compartment, vIDs));
    
    % Species is input/conc. doesn't change due to reactions, etc.
    isu(i) = species.boundaryCondition || species.constant;
    
    % Species substance units in amount/true or conc./false
    xuSubstanceUnits(i) = logical(species.hasOnlySubstanceUnits);
end

%% Parameters
nk  = length(sbml.parameter); % Total number of parameters (may change)
nkm = nk; % Number of model parameters
kIDs   = cell(nk,1);
kNames = cell(nk,1);
k      = zeros(nk,1);

% Get model parameters
for ik = 1:nk
    kIDs{ik}   = sbml.parameter(ik).id;
    kNames{ik} = sbml.parameter(ik).name;
    k(ik)      = sbml.parameter(ik).value;
end

%% Reactions
nr = length(sbml.reaction);

% Local parameters
for i = 1:nr
    kineticLaw = sbml.reaction(i).kineticLaw; % Will be empty if no kinetic law parameters exist
    if ~isempty(kineticLaw)
        constantskl = kineticLaw.parameter; % Will only fetch parameters unique to this kinetic law
        nkkl = length(constantskl);
        for j = 1:nkkl
            nk = nk + 1; % Add one more parameter
            kIDs{nk,1}   = constantskl(j).id;
            kNames{nk,1} = constantskl(j).name;
            k(nk,1)      = constantskl(j).value;
        end
    end
end

%% Done extracting model variables
if verbose; fprintf('done.\n'); end

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 2: Convert to symbolics %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if verbose; fprintf('Converting to symbolics...'); end

%% Compartments
vSyms = sym(vIDs);

%% Species
xuSyms = sym(xuIDs);

%% Parameters
kSyms = sym(kIDs);

%% Done converting to symbolics
if verbose; fprintf('done.\n'); end

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 3: Building the Diff Eqs %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if verbose; fprintf('Building diff eqs...'); end

%% Assemble rules expressions
% Orders ruls by repeated, then initial assignments
% Note: libSBML breaks original ordering?
nRules = length(sbml.rule);

% Rule types:
%   0 = repeated assignment
%   1 = initial assignment
assignmentTypes = zeros(nRules,1);
if isfield(sbml, 'initialAssignment')
    nInitialAssignments = length(sbml.initialAssignment);
    nRules = nRules + nInitialAssignments;
    assignmentTypes = [assignmentTypes; ones(nInitialAssignments,1)];
end

% Store targets and values
targetStrs = [{sbml.rule.variable}'];
valueStrs  = [{sbml.rule.formula}' ];

if isfield(sbml, 'initialAssignment')
    targetStrs = [targetStrs; {sbml.initialAssignment.symbol}'];
    valueStrs  = [valueStrs;  {sbml.initialAssignment.math}'];
end

% Turn into symbolics
targetSyms = sym(targetStrs);
valueSyms  = sym(valueStrs);
valueSymVars = cell(nRules,1);

% Make lookup function indicating which values are constant
allIDs = [xuIDs; kIDs; vIDs];
allConstants = [isu; logical([sbml.parameter.constant]'); logical([sbml.compartment.constant]')];
isConstant = @(var) allConstants(strcmp(var, allIDs));

substitute = false(nRules,1);
makeoutput = false(nRules,1);
setseedvalue = false(nRules,1);
setparametervalue = false(nRules,1);
setcompartmentvalue = false(nRules,1);
addcompartmentexpr = false(nRules,1);

for i = 1:nRules
    
    if assignmentTypes(i) == 0 % Repeated assignments
        
        substitute(i) = true;
        makeoutput(i) = true;
        
    elseif assignmentTypes(i) == 1 % Initial assignments
        
        % Get strings of all variables in valueSyms
        thisvalueStrs = arrayfun(@char, symvar(valueSyms(i)), 'UniformOutput', false);
        
        % Check whether initialAssignment is from constants to constants.
        % Initial assignment to constants from constants can be treated the
        % same as repeatedAssignment, since neither the assignees or
        % assigners change with time. Initial assignments to species from
        % constants can be treated as seed parameters if the assigner (1)
        % only assigns to species and (2) only appears with other seed
        % parameters. Any other case will not work quite the same as it
        % does in SimBiology, since there is currently no way in
        % KroneckerBio to enforce the rule's constraint after the model is
        % built.
        
        % Determine whether target and values are constants
        targetIsConstant = isConstant(targetStrs{i});
        valueIsConstant = arrayfun(isConstant, thisvalueStrs);
        
        % Determine variable types of target and values
        targetIsSpecies       = any(strcmp(targetStrs{i}, xuIDs));
        targetIsParameter     = any(strcmp(targetStrs{i}, kIDs));
        targetIsCompartment   = any(strcmp(targetStrs{i}, vIDs));
        valuesAreParameters   = any(cellfun(@strcmp, repmat(thisvalueStrs(:), 1, nk), repmat(kIDs(:)', length(thisvalueStrs), 1)), 2);
        valuesAreSpecies      = any(cellfun(@strcmp, repmat(thisvalueStrs(:), 1, nxu), repmat(xuIDs(:)', length(thisvalueStrs), 1)), 2);
        valuesAreCompartments = any(cellfun(@strcmp, repmat(thisvalueStrs(:), 1, nv), repmat(vIDs(:)', length(thisvalueStrs), 1)), 2);
        
        % If all the associated values are constants...
        if targetIsConstant && all(valueIsConstant)
            
            % Perform substitution to enforce the rule
            substitute(i) = true;
            
            % If the target is a species, set up an output. Otherwise
            % don't.
            if targetIsSpecies
                makeoutput(i) = true;
            end
            
        else % If some values are not constant...
            
            warning([targetStrs{i} ' will be set to ' valueStrs{i} ' initially, but if ' strjoin(thisvalueStrs, ',') ' is/are changed following model initialization, ' targetStrs{i} ' must be updated manually to comply with the rule.'])
            
            if targetIsSpecies
                setseedvalue(i) = true;
            elseif targetIsParameter
                setparametervalue(i) = true;
            elseif targetIsCompartment
                setcompartmentvalue(i) = true;
            end
            
        end
    end
    
end

%% States and Outputs
nx = nnz(~isu);
xIDs   = xuIDs(~isu);
xNames = xuNames(~isu);
xSyms  = xuSyms(~isu);
x0     = sym(xu0(~isu));
vxInd  = vxuInd(~isu);

% Represent every state's initial condition with a seed
ns = nx;
sNames = xIDs;
sIDs = sprintf('seed%dx\n',(1:ns)');
sIDs = textscan(sIDs,'%s','Delimiter','\n');
sIDs   = sIDs{1};
sSyms  = sym(sIDs);
s      = xu0(~isu);

nu = nnz(isu);
uIDs   = xuIDs(isu);
uNames = xuNames(isu);
uSyms  = xuSyms(isu);
u      = sym(xu0(isu));
vuInd  = vxuInd(isu);

% Input parameters don't have an analog in SBML
nq = 0;
qSyms = sym(zeros(0,1));
qIDs   = cell(0,1);
qNames = cell(0,1);
q = zeros(0,1);

%% Reactions
% Need to apply assignment rules to rate forms
nSEntries = 0;
SEntries  = zeros(0,3);
rIDs   = cell(nr,1);
rNames = cell(nr,1);
rStrs  = cell(nr,1);

% Get each reaction and build stochiometry matrix
for i = 1:nr
    reaction = sbml.reaction(i);
    
    % Get reaction name
    rIDs{i}   = reaction.id;
    rNames{i} = reaction.name;
    
    % Get reaction rate
    rStrs{i,1} = reaction.kineticLaw.math; % check this or formula
    
    % Tally new entries
    nReactants = length(reaction.reactant);
    nProducts = length(reaction.product);
    nAdd = nReactants + nProducts;
    
    % Add more room in vector if necessary
    currentLength = size(SEntries,1);
    if nSEntries + nAdd > currentLength
        addLength = max(currentLength, 1);
        SEntries = [SEntries; zeros(addLength,3)];
    end
    
    % Build stoichiometry matrix
    for j = 1:nReactants
        reactant = reaction.reactant(j).species;
        stoich = -reaction.reactant(j).stoichiometry;
        ind = find(strcmp(xuIDs, reactant));
        
        nSEntries = nSEntries + 1;
        SEntries(nSEntries,1) = ind;
        SEntries(nSEntries,2) = i;
        
        if xuSubstanceUnits(ind) % Both stoichiometry and species are in amount
            SEntries(nSEntries,3) = stoich;
        else % Stoichiometry is in concentration, reactions are in amount
            SEntries(nSEntries,3) = stoich / v(vxuInd(ind));
        end
        
    end
    
    for j = 1:nProducts
        product = reaction.product(j).species;
        stoich = reaction.product(j).stoichiometry;
        ind = find(strcmp(xuIDs, product));
        
        nSEntries = nSEntries + 1;
        SEntries(nSEntries,1) = ind;
        SEntries(nSEntries,2) = i;
        
        if xuSubstanceUnits(ind) % Both stoichiometry and species are in amount
            SEntries(nSEntries,3) = stoich;
        else % Stoichiometry is in concentration, reactions are in amount
            SEntries(nSEntries,3) = stoich / v(vxuInd(ind));
        end
    end
end

% Symbolically evaluate r
r = sym(rStrs);

% Assemble stoichiometry matrix
S = sparse(SEntries(1:nSEntries,1), SEntries(1:nSEntries,2), SEntries(1:nSEntries,3), nxu, nr);
Su = S(isu,:);
S = S(~isu,:);

%% Substitute assignment rules into reaction rates
% This may require up to nRules iterations of substitution
% nRules^2 time complexity overall
subsRules = find(substitute);
for i = subsRules(:)'
    r = subs(r, targetSyms(subsRules), valueSyms(subsRules));
end

% Delete rule parameters
[kSyms, kNames, k, nk] = deleteRuleParameters(kSyms, kNames, k, targetSyms, substitute);
[xSyms, xNames, s, nx, found] = deleteRuleParameters(xSyms, xNames, s, targetSyms, substitute);
sSyms(found(found ~= 0)) = [];
sNames(found(found ~= 0)) = [];
[uSyms, uNames, u, nu] = deleteRuleParameters(uSyms, uNames, u, targetSyms, substitute);

% Convert rule terms to outputs
%   This is optional but convenient
%   Make sure to add additional outputs as desired when building model
y = valueSyms(makeoutput);
yNames = arrayfun(@char, targetSyms, 'UniformOutput', false);

% Substitute values for initial assignments
for i = 1:nRules
    % If this is an initial assignment rule...
    if setseedvalue(i) || setparametervalue(i) || setcompartmentvalue(i)
        target = targetSyms(i);
        valuestoassign = valueSyms(i);
        valuestoassign = subs(valuestoassign, [xSyms; uSyms; kSyms; vSyms], [s; u; k; v]);
        if setseedvalue(i)
            seedtargets_i = find(logical(target == xSyms));
            if isempty(seedtargets_i)
                inputtargets_i = find(logical(target == uSyms));
                u(inputtargets_i) = double(valuestoassign);
            else
                s(seedtargets_i) = double(valuestoassign);
            end
        elseif setparametervalue(i)
            paramtargets_i = find(logical(target == kSyms));
            k(paramtargets_i) = double(valuestoassign);
        elseif setcompartmentvalue(i)
            compartmenttargets_i = find(logical(target == vSyms));
            v(compartmenttargets_i) = double(valuestoassign);
        end
    end
end

%% Done building diff eqs
if verbose; fprintf('done.\n'); end

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 5: Use human readable names instead of IDs if desired %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if opts.UseNames
    if verbose; fprintf('Converting IDs to names...'); end
    vIDs = vNames;
    kIDs = kNames;
    sIDs = sNames;
    qIDs = qNames;
    uIDs = uNames;
    xIDs = xNames;
    rIDs = rNames;
    if verbose; fprintf('done.\n'); end
end

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 6: Build Symbolic Model %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
symModel.Type       = 'Model.SymbolicReactions';
symModel.Name       = name;

symModel.nv         = nv;
symModel.nk         = nk;
symModel.ns         = ns;
symModel.nq         = nq;
symModel.nu         = nu;
symModel.nx         = nx;
symModel.nr         = nr;

symModel.vSyms      = vSyms;
symModel.vNames     = vIDs;
symModel.dv         = dv;
symModel.v          = v;

symModel.kSyms      = kSyms;
symModel.kNames     = kIDs;
symModel.k          = k;

symModel.sSyms      = sSyms;
symModel.sNames     = sIDs;
symModel.s          = s;

symModel.qSyms      = qSyms;
symModel.qNames     = qIDs;
symModel.q          = q;

symModel.uSyms      = uSyms;
symModel.uNames     = uIDs;
symModel.vuInd      = vuInd;
symModel.u          = u;

symModel.xSyms      = xSyms;
symModel.xNames     = xIDs;
symModel.vxInd      = vxInd;
symModel.x0         = x0;

symModel.rNames     = rIDs;
symModel.r          = r;
symModel.S          = S;
symModel.Su         = Su;

symModel.y          = y;
symModel.yNames     = yNames;

end

%% %%%%%%%%%%%%%%%%%
% Helper Functions %
%%%%%%%%%%%%%%%%%%%%
function [kSyms, kNames, k, nk, found] = deleteRuleParameters(kSyms, kNames, k, targetSyms, substitute)

if isempty(kSyms)
    nk = numel(kSyms);
    found = [];
    return
end

found = lookup(targetSyms(substitute), kSyms);
kSyms(found(found ~= 0)) = [];
kNames(found(found ~= 0)) = [];
k(found(found ~= 0)) = [];
nk = numel(kSyms);

end