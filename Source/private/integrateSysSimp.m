function int = integrateSysSimp(m, con, tF, eve, fin, t_get, opts)

% Constants
nx = m.nx;

y = m.y;
u = con.u;

% Construct system
[der, jac, del] = constructSystem();

if ~con.SteadyState
    ic = m.dx0ds * con.s + m.x0c;
else
    ic = steadystateSys(m, con, opts);
end

% Integrate f over time
sol = accumulateOdeFwdSimp(der, jac, 0, tF, ic, con.Discontinuities, t_get, 1:nx, opts.RelTol, opts.AbsTol(1:nx), del, eve, fin);

% Work down
int.Type = 'Integration.System.Simple';
int.Name = [m.Name ' in ' con.Name];

int.nx = nx;
int.ny = m.ny;
int.nu = m.nu;
int.nk = m.nk;
int.ns = m.ns;
int.nq = con.nq;
int.nh = con.nh;
int.k = m.k;
int.s = con.s;
int.q = con.q;
int.h = con.h;

int.dydx = m.dydx;
int.dydu = m.dydu;

int.t = sol.x;
int.x = sol.y;
int.u = con.u(int.t);
int.y = y(int.t, int.x, int.u);

int.ie = sol.ie;
int.te = sol.xe;
int.xe = sol.ye(1:nx,:);
int.ue = u(int.te);
int.ye = y(int.te, int.xe, int.ue);

int.sol = sol;

% End of function
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% The system for integrating f %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    function [der, jac, del] = constructSystem()
        f     = m.f;
        dfdx  = m.dfdx;
        u    = con.u;
        d     = con.d;
        dx0ds = m.dx0ds;
        
        y = m.y;
        
        der = @derivative;
        jac = @jacobian;
        del = @delta;
        
        % Derivative of x with respect to time
        function val = derivative(t, x)
            u_t = u(t);
            val = f(t, x, u_t);
        end
        
        % Jacobian of x derivative
        function val = jacobian(t, x)
            u_t = u(t);
            val = dfdx(t, x, u_t);
        end
        
        % Dosing
        function val = delta(t, x)
            val = dx0ds * d(t);
        end
    end
end