function result = run_cpms_shift(varargin)
%RUN_CPMS_SHIFT Run one baseline DSS cycle for the CPMS project.
%
%   RESULT = RUN_CPMS_SHIFT() reads the latest RS outputs, computes KPIs,
%   generates ReleaseTable and RoutingTable decisions, and writes them to
%   the configured RS input folder.
%
%   RESULT = RUN_CPMS_SHIFT(CONFIG) overrides the default configuration with
%   fields in CONFIG.
%
%   RESULT = RUN_CPMS_SHIFT('Name', Value, ...) overrides individual config
%   fields. See +cpms/defaultConfig.m for the supported fields.

config = cpms.defaultConfig();

if nargin == 1 && isstruct(varargin{1})
    config = cpms.mergeStruct(config, varargin{1});
elseif nargin > 0
    if mod(nargin, 2) ~= 0
        error('run_cpms_shift:InvalidArguments', ...
            'Use either a config struct or name/value pairs.');
    end
    overrides = struct(varargin{:});
    config = cpms.mergeStruct(config, overrides);
end

result = cpms.runShift(config);
end
