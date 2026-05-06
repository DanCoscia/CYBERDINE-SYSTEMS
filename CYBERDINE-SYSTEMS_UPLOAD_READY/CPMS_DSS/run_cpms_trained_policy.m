function result = run_cpms_trained_policy(varargin)
%RUN_CPMS_TRAINED_POLICY Apply the saved best GA policy without retraining.
%
%   RESULT = RUN_CPMS_TRAINED_POLICY() loads the best genome saved by weekly
%   GA/DM training, generates the next shift's ReleaseTable and RoutingTable,
%   and writes the decision files. It does not run Tecnomatix and does not
%   update the GA state.
%
%   RESULT = RUN_CPMS_TRAINED_POLICY('ShiftStart', datetime(...)) writes the
%   locked policy for a specific shift start.
%
%   RESULT = RUN_CPMS_TRAINED_POLICY('UseDigitalModelScoring', true) rehearses
%   only the locked policy in the Digital Model. It does not create new GA
%   candidates and does not update the saved GA state.

config = cpms.defaultConfig();
config.UseDigitalModelScoring = false;
config.UsePersistentGaTraining = false;
config.UseTrainedGaPolicyOnly = true;
config.ScoreTrainedGaPolicy = true;
config.TrainedPolicyMode = "weekly";
config.TrainingCampaignMode = "shift";

if nargin == 1 && isstruct(varargin{1})
    config = cpms.mergeStruct(config, varargin{1});
elseif nargin > 0
    if mod(nargin, 2) ~= 0
        error('run_cpms_trained_policy:InvalidArguments', ...
            'Use either a config struct or name/value pairs.');
    end
    overrides = struct(varargin{:});
    config = cpms.mergeStruct(config, overrides);
end

result = cpms.runShift(config);
end
