# CPMS Matlab DSS

This project is the Matlab decision-support layer for the CPMS course model.
It reads the supplied system state and first-week logs, writes valid Digital
Model input workbooks, and can train release/routing plans through the Siemens
Tecnomatix Plant Simulation Digital Model.

The real-system executor is intentionally not called by this code.

## Project KPI Contract

The course brief defines four mandatory KPIs. These are the main KPIs used in
the DSS reports and in the current GA/DM scoring objective:

- `WIP`: parts currently inside the system, read from `SysState.xlsx`.
- `CumProdShift`: completed parts per shift, counted at Stage 4 exits
  (`M11`-`M14`).
- `SigmaCumProd<k>`: standard deviation of daily production for each
  `PT1`-`PT5` over the campaign/week.
- `PlanEffShift`: planned release adherence. In RS log analysis this compares
  planned releases with parts that were effectively released/produced. In DM
  scoring it is approximated from planned release totals versus completed
  production, with over-release penalized because exact by-part WIP ownership
  is not exported by the DM runner.

The optional KPI families are also extracted or scored when available:
`AvLeadTime`, `InterDepTime`, `InterDepTimeS4`, `Throughput<k>`, and
`SaturationM<m>`.

## Current Important Findings

- **Do not use `DSS_Output\DM_Work` for trusted GA scoring.** The copied
  Tecnomatix model can validate Excel inputs but produce candidate-invariant
  scores. The default is now `UseDmWorkingCopy=false`, so DM scoring runs in
  the native `C:\Users\dania\Documents\DM_student` folder.
- **Trusted scoring uses the course `dm_config.p` and `dm_run.p` path.** The
  custom live COM runner is kept for diagnostics only.
- **GA comparisons use common random numbers.** The Matlab RNG is reset before
  each official `dm_run.p` candidate so candidates see the same stochastic seed
  sequence.
- **Excel workbooks are replaced fresh before writing.** This avoids the old
  bug where a 5-row shift plan could leave stale rows from a previous 50-row
  weekly plan inside `ReleaseTable.xlsx`.
- **The Real System is still never executed here.** After training, use
  `run_cpms_trained_policy()` to write the locked one-shift handoff files.

## Copy/Paste Commands

Use these from the Matlab Command Window. The first two lines are the setup
for every command below:

```matlab
cd('C:\Users\dania\OneDrive - Politecnico di Milano\Documents\New project');
addpath(pwd);
```

### Validate Tables Only

This does not run Tecnomatix and does not touch the Real System.

```matlab
result = validate_cpms_outputs();
```

Keep the validation files for inspection:

```matlab
result = validate_cpms_outputs('KeepFiles', true);
```

### Diagnose Readiness

This checks the active DM input workbooks, current SysState, saved GA state,
and latest DM production log. It does not run Tecnomatix and does not touch the
Real System.

```matlab
report = diagnose_cpms_project();
report.Summary
report.Issues
```

### Generate Current Decision Tables Without DM Scoring

This reads the current files/logs and writes Release/Routing/Cycle tables, but
does not run Tecnomatix and does not touch the Real System.

```matlab
result = run_cpms_shift('UseDigitalModelScoring', false);
```

Inspect what was written:

```matlab
result.WrittenFiles
head(result.ReleaseTable)
result.RoutingTable
result.CycleTimeTable
```

### Generate Full-Horizon Plan Without DM Scoring

Use this when you want the full dated plan across the project horizon but do
not want to run Tecnomatix yet.

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', false, ...
    'TrainingCampaignMode', "full");
```

### Run Fresh Weekly GA Training

This launches Tecnomatix Plant Simulation through COM in the native
`DM_student` folder. It runs one weekly campaign per candidate using the
official p-coded course runner and saves new GA state/history files afterward.
The current GA objective gives PT5 a higher shortfall penalty and applies a
direct penalty when machine saturation runs above the configured target. That
means the best candidate should be less willing to push machines near 100%
saturation just to gain a little extra throughput.

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', true, ...
    'TrainingCampaignMode', "weekly", ...
    'NumReleaseCandidates', 5, ...
    'DmReplications', 8);
```

Inspect candidate scores after the run:

```matlab
result.DigitalModelScores
sortrows(result.DigitalModelScores, 'Score', 'descend')
```

### Run Short Digital Model Smoke Test

This launches Tecnomatix, but keeps the simulated horizon intentionally tiny.
The official p-coded runner still performs its internal replication campaign;
use it to test that COM, `dm_config`, the validators, and result collection
are working.

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', true, ...
    'NumReleaseCandidates', 1, ...
    'DmHorizonHours', 0.02, ...
    'EnableLiveDashboard', false);
```

### Run Full-Horizon Evaluation

This launches Tecnomatix. Internally, full horizon is evaluated as weekly
Digital Model subcampaigns and aggregated; it is not one monolithic run.

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', true, ...
    'TrainingCampaignMode', "full", ...
    'NumReleaseCandidates', 5, ...
    'DmReplications', 8);
```

### Inspect The Saved Best Candidate

Use this after at least one GA/DM scoring run. The weekly state is usually the
best policy source for shift-by-shift real-system execution.

```matlab
config = cpms.resolveConfig(cpms.defaultConfig());
S = load(config.TrainingStateFile, 'trainingState');
trainingState = S.trainingState;

trainingState.Generation
trainingState.BestScore
trainingState.BestNormalizedScore
trainingState.BestGenome
trainingState.History
```

Inspect the saved full-horizon best candidate instead:

```matlab
config = cpms.defaultConfig();
config.TrainingCampaignMode = "full";
config.TrainingStateFile = "";
config.TrainingHistoryFile = "";
config = cpms.resolveConfig(config);

S = load(config.TrainingStateFile, 'trainingState');
trainingState = S.trainingState;

trainingState.Generation
trainingState.BestScore
trainingState.BestNormalizedScore
trainingState.BestGenome
trainingState.History
```

### Apply The Saved Best Candidate Only

This is the real-system-style mode. It loads the saved best GA genome, applies
it as a locked policy, writes Release/Routing/Cycle tables, and does not run
Tecnomatix or update the GA.

```matlab
result = run_cpms_trained_policy();
```

Confirm the active ReleaseTable really contains only the rows just written:

```matlab
T = readtable('C:\Users\dania\Documents\DM_student\ReleaseTable.xlsx', ...
    'VariableNamingRule', 'preserve');

height(T)
sum(T.Number)
T
```

For a single shift, the locked policy still reads the latest SysState/log KPIs.
The baseline release planner computes a WIP-aware shift release, then the saved
best genome scales that release pressure and supplies the trained routing
weights. In other words, the genome is fixed, but the shift decision still
responds to the latest observed system state.

Apply the locked policy to a specific shift start:

```matlab
result = run_cpms_trained_policy( ...
    'ShiftStart', datetime(2025,11,17,6,30,0));
```

Use the full-horizon trained policy instead of the weekly trained policy:

```matlab
result = run_cpms_trained_policy( ...
    'TrainedPolicyMode', "full", ...
    'ShiftStart', datetime(2025,11,17,6,30,0));
```

Rehearse only the full-horizon champion in the Digital Model. This launches
Tecnomatix, but it runs one locked candidate only. It does not create a new GA
population and does not update the saved GA state.

```matlab
championDm = run_cpms_trained_policy( ...
    'TrainedPolicyMode', "full", ...
    'TrainingCampaignMode', "full", ...
    'UseDigitalModelScoring', true, ...
    'DmReplications', 8, ...
    'NumReleaseCandidates', 1);

championDm.DigitalModelScores
championDm.WrittenFiles
```

Write a one-day RS-style plan using only the full-horizon champion. This does
not run Tecnomatix. Inspect the Excel files, then you can manually run the Real
System once outside this DSS.

```matlab
dayPlan = run_cpms_trained_policy( ...
    'TrainedPolicyMode', "full", ...
    'TrainingCampaignMode', "customhours", ...
    'DmHorizonHours', 16, ...
    'ShiftStart', datetime(2025,11,17,6,30,0), ...
    'UseDigitalModelScoring', false);

dayPlan.WrittenFiles
dayPlan.ReleaseTable
dayPlan.RoutingTable
```

Rehearse that same one-day plan in the Digital Model before you trust it for
the Real System:

```matlab
dayDm = run_cpms_trained_policy( ...
    'TrainedPolicyMode', "full", ...
    'TrainingCampaignMode', "customhours", ...
    'DmHorizonHours', 16, ...
    'ShiftStart', datetime(2025,11,17,6,30,0), ...
    'UseDigitalModelScoring', true, ...
    'DmReplications', 8, ...
    'NumReleaseCandidates', 1);

dayDm.DigitalModelScores
```

Inspect the files that would be handed to the next RS/DM step:

```matlab
result.DigitalModelScores
result.WrittenFiles
head(result.ReleaseTable)
result.RoutingTable
result.CycleTimeTable
```

### Apply The Locked Policy Shift By Shift

The Real System should not be used for repeated training. The intended pattern
is:

1. train in DM,
2. lock the best policy,
3. write one shift/day decision,
4. run the Real System externally once,
5. copy/read the new RS outputs,
6. repeat the locked-policy command for the next shift/day.

Example command list for the first two shifts. Run the Real System yourself
between the two commands after checking the produced Excel files.

```matlab
morning = run_cpms_trained_policy( ...
    'ShiftStart', datetime(2025,11,17,6,30,0));

% Run the Real System externally once, then make sure the new SysState/logs
% are available before continuing.

afternoon = run_cpms_trained_policy( ...
    'ShiftStart', datetime(2025,11,17,14,30,0));
```

Example command list for production-day DM rehearsals using only the locked
full-horizon champion. This can take a long time because it launches one DM
campaign per production day; test one day first.

```matlab
cfg = cpms.defaultConfig();
firstDay = datetime(2025,11,17);
lastDay = dateshift(cfg.ProjectEndTime, 'start', 'day');
calendarDays = (firstDay:days(1):lastDay)';

productionDays = calendarDays( ...
    ~ismember(weekday(calendarDays), [1 7]) & ...
    ~ismember(dateshift(calendarDays, 'start', 'day'), cfg.CourseHolidays));

dayStarts = productionDays + hours(6) + minutes(30);
dayResults = cell(numel(dayStarts), 1);

for d = 1:numel(dayStarts)
    fprintf('Champion DM day rehearsal %d/%d: %s\n', ...
        d, numel(dayStarts), char(string(dayStarts(d))));

    dayResults{d} = run_cpms_trained_policy( ...
        'TrainedPolicyMode', "full", ...
        'TrainingCampaignMode', "customhours", ...
        'DmHorizonHours', 16, ...
        'ShiftStart', dayStarts(d), ...
        'UseDigitalModelScoring', true, ...
        'DmReplications', 8, ...
        'NumReleaseCandidates', 1);
end
```

### Read The Production Log After DM Scoring

This only works after at least one run with `UseDigitalModelScoring=true`,
because the log is recreated from scratch after a GA reset.

```matlab
logFile = fullfile(pwd, 'DSS_Output', 'cpms_dm_production_log.xlsx');
sheetnames(logFile)

candidateSummary = readtable(logFile, ...
    'Sheet', 'CandidateSummary', ...
    'VariableNamingRule', 'preserve');

kpiAvg = readtable(logFile, ...
    'Sheet', 'KPI_Avg', ...
    'VariableNamingRule', 'preserve');

candidateSummary
kpiAvg
```

### Compare Saved Candidates

This reads `DSS_Output\cpms_dm_production_log.xlsx`, compares saved candidates,
sorts them by normalized score, and opens a comparison plot. It does not run
Tecnomatix or the Real System.

```matlab
comparison = compare_cpms_candidates();
```

Hide exact duplicates from repeated rehearsals:

```matlab
comparison = compare_cpms_candidates('UniqueOnly', true);
```

Only compare saved full-horizon candidates:

```matlab
comparison = compare_cpms_candidates('CampaignMode', "full");
```

Only show the latest saved candidate batch and skip the figure:

```matlab
comparison = compare_cpms_candidates( ...
    'LatestOnly', true, ...
    'ShowPlot', false);
```

### Reset GA Training Again

This clears only DSS-generated GA memory/log files. It does not remove
`DSS_Output\DM_Work`, does not run Tecnomatix, and does not touch the Real
System.

```matlab
patterns = { ...
    'cpms_ga_training*.mat', ...
    'cpms_ga_history*.xlsx', ...
    'cpms_dm_production_log.xlsx'};

for p = 1:numel(patterns)
    files = dir(fullfile(pwd, 'DSS_Output', patterns{p}));
    for k = 1:numel(files)
        delete(fullfile(files(k).folder, files(k).name));
    end
end
```

## Main Workflow

Run from this folder in Matlab:

```matlab
cd('C:\Users\dania\OneDrive - Politecnico di Milano\Documents\New project');
addpath(pwd);
result = run_cpms_shift();
```

That reads the current Digital Model state/logs and writes:

```text
C:\Users\dania\Documents\DM_student\ReleaseTable.xlsx
C:\Users\dania\Documents\DM_student\RoutingTable.xlsx
C:\Users\dania\Documents\DM_student\CycleTimeTable.xlsx
```

To validate without touching the active Digital Model folder:

```matlab
validate_cpms_outputs('KeepFiles', true);
```

`validate_cpms_outputs` writes only under `DSS_Output\validation_latest` when
`KeepFiles` is true. It does not synchronize those validation files back into
`DSS_Output\DM_Work`.

To regenerate the active full-horizon release/routing/cycle input workbooks
without running Tecnomatix or the Real System:

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', false, ...
    'TrainingCampaignMode', "full");
```

## Digital Model Training

Default DM training is now a weekly campaign. When Digital Model scoring is
enabled, the DSS evaluates candidate plans in the native
`C:\Users\dania\Documents\DM_student` folder using the official course
`dm_config.p` and `dm_run.p` files. It runs the Digital Model campaign for each
candidate, collects the returned KPI tables, and persists the best genome for
the next training call. Weekly training has one campaign per candidate.
Full-horizon evaluation is split into weekly subcampaigns so later weeks keep
their own ReleaseTable/configuration cycle instead of depending on one long
black-box run.

```matlab
result = run_cpms_shift('UseDigitalModelScoring', true);
```

GA state is split by campaign mode. Weekly training uses
`DSS_Output\cpms_ga_training_weekly.mat` and
`DSS_Output\cpms_ga_history_weekly.xlsx`; full-horizon training uses
`DSS_Output\cpms_ga_training_full.mat` and
`DSS_Output\cpms_ga_history_full.xlsx`. This prevents weekly scores and
full-horizon scores from competing inside one persistent GA state.

The GA state also has a scoring-objective version. If the score formula
changes, old saved genomes are ignored automatically because their scores are
not comparable to the new objective. The current KPI-aligned scoring objective
uses `GaStateVersion = 8`, so older `.mat` training states are ignored by the
next training command even if they are still present.

The current scorer is robust across replications: it scores each stochastic DM
replication and subtracts a penalty for high score variance. A candidate must
therefore perform reasonably across repeated runs, not merely win one lucky
campaign. This is closer to the Real System constraint, where the selected
policy only gets one real execution chance.

Training also uses common random numbers by default. Every candidate in a
generation is evaluated on the same deterministic seed list, so candidate
comparisons are not dominated by one plan getting an easy random week while
another gets a hard random week. The seed used for each replication is logged
in `KPI_Runs`.

GA candidate generation uses a separate random seed from the Digital Model.
This matters because the official `dm_run.p` path resets Matlab's RNG to keep
candidate simulations fair. The DSS reseeds the GA before building the next
population and rejects duplicate genomes, so repeated training calls do not
burn Tecnomatix time on the same candidate set.

Useful smoke test:

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', true, ...
    'NumReleaseCandidates', 1, ...
    'DmHorizonHours', 0.02, ...
    'EnableLiveDashboard', false);
```

Full final-horizon evaluation should be explicit:

```matlab
result = run_cpms_shift( ...
    'UseDigitalModelScoring', true, ...
    'TrainingCampaignMode', "full", ...
    'DmReplications', 8);
```

In this DSS, `TrainingCampaignMode="full"` no longer means one monolithic
Tecnomatix run to 26.12.2025. The full release table is still generated over
the whole project horizon, but the Digital Model score is computed by splitting
that table into weekly windows, running each week through the DM, and
aggregating the weekly outputs. This matches the observed DM interface: one
long run can stop importing later releases after the first week, while weekly
campaigns keep the release table, `dm_config`, and result tables aligned.

`DmHorizonHours` is still available for custom smoke tests or final checks, but
normal training should use the weekly campaign default. Per-shift campaigns are
more faithful but usually too slow. Full-horizon evaluation is useful as a
final check, but it is evaluated as weekly aggregate campaigns rather than as
one black-box 7-week DM run.

## Calendar Rules

The DSS uses the course production calendar:

- valid shift starts are `06:30` and `14:30`,
- valid release windows are `06:30-14:00` and `14:30-22:00`,
- weekends are non-production days,
- course holidays `2025-12-08`, `2025-12-25`, and `2025-12-26` are
  non-production days.

`config.ShiftLengthHours` is `7.5`, matching the scheduled shift windows and
the observed Digital Model relation `TotalProduction = TotalThroughput * 7.5`.
The ReleaseTable validator now rejects weekend, holiday, and out-of-window
release rows.

## Diagnostic Live Dashboard

The live runner is `+cpms/runDigitalModelLive.m`. It is now diagnostic only and
is disabled by default because the copied/COM runner did not reproduce every
hidden side effect of the official `dm_config.p`/`dm_run.p` workflow. Trusted
GA scoring should keep `UseLiveDigitalModelRunner=false`.

With the trusted official `dm_run.p` path, `EnableLiveDashboard=true` now opens
or refreshes a post-campaign dashboard after each candidate/campaign finishes.
It is not a true live mid-replication plot, but it uses the same returned DM
tables that are scored and logged, so it is the safer dashboard for real
decision work.

When enabled for debugging, the dashboard reuses one figure window across
candidates and can plot:

- throughput by part type over shifts,
- daily production by part type,
- production totals against the campaign target,
- WIP proxy from average buffer levels across completed campaigns,
- machine saturation for `M1` through `M14`,
- candidate summary.

Dashboard X axes are calendar-aware in the diagnostic runner. Shift plots use
the number of valid production shift starts in the campaign. Daily plots group
those shift rows by the actual production dates, so partial weeks and holiday
weeks do not get stretched or compressed into fake days. Full-horizon scoring
is executed as weekly Digital Model subcampaigns; diagnostic plots stitch those
weekly parts back together by candidate instead of resetting to local DM day 1.

If you deliberately enable the diagnostic runner, it uses a safe heartbeat
while the event controller is running and reads heavy Tecnomatix result tables
after each replication finishes. The figure is refreshed at campaign boundaries
by default (`DashboardUpdateGranularity = "campaign"`), not after every
replication. This avoids a COM blocking problem observed on replication 2 and
makes the plots compare candidates instead of individual stochastic runs. If
you want to experiment with true mid-run table reads, pass
`'LivePollMetricsDuringRun', true` and
`'DashboardUpdateGranularity', "replication"`, but use a short horizon first.

The target markers are scaled to the campaign: weekly campaigns use one weekly
target, full/final campaigns multiply the weekly target by the number of
campaign weeks, and short smoke tests use a fractional target. For
full-horizon runs, the logged production and scores come from the weekly
aggregate result, not from a single long Tecnomatix run. The cumulative daily
plot uses `TH_SHIFT` aggregated by production day when that table has enough
nonzero shift rows, multiplying the `TH_SHIFT` rate by the 7.5-hour shift
length before labeling the result as parts. Otherwise it shows the raw
`CUMPROD_DAY` export as DM periods. It does not invent missing daily rows.

For weekly or final campaigns, GA candidate release tables are spread across
the production shifts in the campaign. This prevents the earlier failure mode
where one small next-shift release table starved the DM after the first two
days of a weekly run. The DSS also runs `dm_config` after writing each
candidate input set so the `.spp` model reloads the current Excel files before
simulation.

The same run still collects the standard Digital Model outputs:

- `ThPerShift` from `.Models.Model.TH_SHIFT`,
- `DailyCumProd` from `.Models.Model.CUMPROD_DAY`,
- `SigmaCumProd` and `AvgLeadTime` from `.Models.Model.PT_stats`,
- `MachSat` and `AvgBuffLevel` from `.Models.Model.BM_stats`.

## Produced Excel Files

### `DM_student\ReleaseTable.xlsx`

Columns: `Release Time`, `Part Type`, `Number`.

This is the current release plan consumed by the Digital Model and, eventually,
by the real-system workflow. Values come from the DSS release policy or the
winning GA genome. With Digital Model scoring disabled it is a current-shift
plan, usually 3-5 rows, unless `TrainingCampaignMode` is set to `"full"`.
With weekly Digital Model scoring enabled it is a weekly schedule spread across
the production shifts in that campaign. With full/final scoring enabled, or
with scoring disabled and `TrainingCampaignMode="full"`, it is the full dated
project-horizon schedule. The DSS splits that table into weekly pieces only
for DM scoring, then keeps the full table as the selected plan.

At the latest verified handoff, `run_cpms_trained_policy()` wrote a clean
one-shift table with 5 rows and total release 49. The active workbook is
deleted before every DSS write, so stale rows from older weekly/full-horizon
plans cannot remain hidden below the current plan.

A regenerated full-horizon table is larger by design: it spreads releases over
the valid production shifts between `2025-11-17 06:30` and
`2025-12-26 14:30`, excluding weekends and course holidays. Use
`diagnose_cpms_project()` after generating a full-horizon table to confirm the
actual row count, total release, and calendar validity before any handoff.

The old legacy file had 320 rows and total release 240,361, including very
large quantities. It was structurally readable but not logical for real-system
use, so it was moved to:

```text
DSS_Output\quarantine\ReleaseTable_quarantined_20260429_162759.xlsx
```

### `DM_student\RoutingTable.xlsx`

Columns: `PT`, then `M1` through `M14`.

Each row is one part type. Values are routing percentages. For every required
stage, the machine percentages sum to 100. `PT1` and `PT5` skip stage 3, so
their `M8:M10` values sum to 0. The current file passes the course validator
and is logically consistent.

### `DM_student\CycleTimeTable.xlsx`

Columns: `M`, `PT1`, `PT2`, `PT3`, `PT4`, `PT5`.

Values are processing times in seconds. They come from first-week entry/exit
logs when enough data exists, with safe defaults filling missing combinations.
The current file has 14 machine rows, no NaNs, nonzero cycle times from 704 to
1386 seconds, and exactly zero stage-3 times for forbidden `PT1`/`PT5` routes.

### `DM_student\SysState.xlsx`

This is the current system-state workbook supplied by the DM/RS workflow. The
DSS reads it to compute WIP and gives the Digital Model the same file as the
starting state. With the trusted defaults, scoring runs in the native
`DM_student` folder, so this workbook is not copied to `DM_Work` unless you
explicitly enable the diagnostic working-copy path. The latest inspected WIP
was 138: PT1=13, PT2=41, PT3=32, PT4=45, PT5=7. That distribution is plausible.

### `DSS_Output\cpms_dm_production_log.xlsx`

This workbook is created during Digital Model scoring and replaced as needed
after a GA reset. If it is absent, run a DM scoring command before trying to
read these sheets.

- `ThPerShift_Runs`: per-replication parts produced per simulated shift.
- `ThPerShift_Avg`: average shift production across replications.
- `DailyCumProd_Runs`: raw DM-exported daily production table per replication.
- `DailyCumProd_Avg`: average of the raw DM daily table.
- `CumulativeProd_Runs`: DSS-computed cumulative production by day.
- `CumulativeProd_Avg`: average DSS-computed cumulative production by day.
- `KPI_Runs`: per-replication KPI summary.
- `KPI_Avg`: average KPI summary across replications.
- `CandidateSummary`: candidate, score, normalized score, campaign mode,
  horizon, release totals, start time, and finish time.
- `LivePolls`: dashboard polling samples collected while Tecnomatix is running.
- `ReleasePlan`: release rows used by each logged candidate.

Important: `DailyCumProd_*` keeps the Digital Model table name for traceability,
but historical values are not always monotonic. Treat those sheets as the raw
DM daily export. Use `CumulativeProd_*` when you need true cumulative progress.
`KPI_*` now keeps both `TotalProduction` from the daily-production table and
`TotalThroughput` from `TH_SHIFT`, since those two DM tables can differ.

### `DSS_Output\cpms_ga_history_<mode>.xlsx`

This workbook is created during GA training. It records generation number, best
raw score, best normalized score, successful candidate count, campaign mode,
horizon hours, start time, and finish time.

Scores from different horizons should be compared with `BestNormalizedScore*`,
not raw `BestScore*`.

### `DSS_Output\cpms_ga_training_<mode>.mat`

This file is created during GA training. It stores the persistent GA state:
previous population, score vector, best genome, and best normalized score. The
state has a version number; incompatible old scoring states are ignored so the
GA does not reuse stale best scores after the campaign-scoring logic changes.
The mode-specific file names keep weekly and full-horizon optimization
separate.

### `DSS_Output\DM_Work`

This is a copied Digital Model folder left from diagnostics. It is not used for
trusted GA scoring by default because the copied model was observed to produce
candidate-invariant scores even when its Excel inputs were valid. Keep
`UseDmWorkingCopy=false` for normal training and real-system handoff
preparation.

### `DSS_Output\quarantine`

Unsafe legacy input workbooks are moved here before the DSS overwrites the
active DM inputs. `quarantine_manifest.xlsx` records source path, quarantine
path, timestamp, and reason.

### Timestamped Archives

Every active DSS write also creates timestamped copies such as:

```text
DSS_Output\ReleaseTable_shift_YYYYMMDD_HHMMSS.xlsx
DSS_Output\RoutingTable_shift_YYYYMMDD_HHMMSS.xlsx
DSS_Output\CycleTimeTable_shift_YYYYMMDD_HHMMSS.xlsx
```

These are audit snapshots of exactly what the DSS produced. Older investigation
snapshots have been moved under:

```text
DSS_Output\archive_investigation_snapshots_*
```

That archive is not needed for normal execution; it is retained only as
debugging evidence from earlier failed runner/copy experiments.

## Current Excel Sanity

- Active `ReleaseTable.xlsx`: logical after the stale-row fix. The latest
  verified trained-policy handoff has 5 rows and total release 49 for the next
  shift. No negative quantities were found.
- Active `RoutingTable.xlsx`: logical; required stage percentages sum to 100,
  and `PT1`/`PT5` stage 3 sums to 0.
- Active `CycleTimeTable.xlsx`: logical; no NaNs, correct forbidden zeros, and
  processing times in the expected range.
- Active `SysState.xlsx`: logical; WIP 138 with a plausible PT mix.
- `cpms_dm_production_log.xlsx`: present after the clean native DM training
  run. Latest candidate scores were not collapsed, which means the trusted
  native DM path is reacting to candidate differences.
- `cpms_ga_history_weekly.xlsx` and `cpms_ga_training_weekly.mat`: present.
  Latest verified weekly state: generation 2, best normalized score about
  `-89.960`. More training can improve this, but validate candidates with
  repeated DM scoring because the real system is stochastic.

## Code Map

The project has two top-level scripts and one Matlab package folder,
`+cpms`. The package folder keeps the real logic out of the top-level folder
so Matlab calls look like `cpms.runShift(...)`.

### Top-level entry points

- `run_cpms_shift.m`: the normal command to run the DSS. It builds the default
  config, applies any name/value overrides, then calls `cpms.runShift`. Use
  this for normal table generation and for Digital Model scoring.
- `run_cpms_trained_policy.m`: applies the saved best GA genome as a locked
  policy for real-system-style execution. By default it writes decision tables
  without running Tecnomatix and without updating GA state. If
  `UseDigitalModelScoring=true`, it rehearses that one locked policy in the DM
  without creating new GA candidates.
- `validate_cpms_outputs.m`: a safe validator-only smoke test. It creates
  temporary Release/Routing/Cycle tables, runs the course validators, and
  removes the temporary files unless `KeepFiles=true`. It does not run
  Tecnomatix and does not call the Real System.

### Main orchestration

- `+cpms/defaultConfig.m`: central default settings. This is where paths,
  weekly targets, shift length, holidays, DM scoring flags, GA parameters,
  dashboard behavior, and output folders are defined.
- `+cpms/resolveConfig.m`: cleans up the config before a run. It normalizes
  paths, finds fallback folders, sets default GA state/history filenames by
  campaign mode, and applies the course calendar defaults.
- `+cpms/runShift.m`: the main pipeline. It reads state/logs, estimates cycle
  times, computes KPIs, generates release candidates and routing, optionally
  scores candidates through the DM/GA, writes the selected Excel tables, and
  returns everything in one `result` struct.

### Input readers and schema handling

- `+cpms/readLatestSysState.m`: reads the current `SysState.xlsx` used to
  restore WIP into the Digital Model.
- `+cpms/readLogs.m`: loads the available first-week RS/DM log files and
  combines them into a common log structure.
- `+cpms/readTableFile.m`: reads one CSV/XLSX table while preserving useful
  column names.
- `+cpms/readWorkbookTables.m`: reads all sheets from a workbook into a struct
  of tables.
- `+cpms/concatPrimaryTables.m`: combines tables from multiple sources into one
  primary table when a workbook/log import returns several sheets.
- `+cpms/findFiles.m`: small file-discovery helper for patterns and folders.
- `+cpms/findLatestFile.m`: returns the newest file matching a pattern.
- `+cpms/matchColumn.m`: finds a table column using candidate names. This keeps
  the parser tolerant of minor column-name differences.
- `+cpms/normalizeNames.m`: normalizes strings/column names for matching.
- `+cpms/tableNumbers.m`: extracts numeric columns safely from imported tables.
- `+cpms/tableStrings.m`: extracts string columns safely from imported tables.
- `+cpms/tableTimes.m`: extracts and converts time columns safely from imported
  tables.
- `+cpms/missingLike.m`: creates a missing value of the same general type as an
  existing value. Used by loose table merging.

### KPI calculation

- `+cpms/computeKpis.m`: collects the required and useful optional KPIs into
  one struct. It calls the WIP, production, lead-time, and saturation modules.
- `+cpms/computeWip.m`: computes total WIP, WIP by part type, and buffer-level
  WIP from `SysState.xlsx`.
- `+cpms/computeProduction.m`: computes shift production, cumulative
  production, production by part type, throughput, and the latest event time
  from the logs.
- `+cpms/computeLeadTimes.m`: estimates lead times by matching part entry and
  final exit events.
- `+cpms/computeMachineSaturation.m`: estimates machine saturation/availability
  signals from logs, especially alarm and machine-related records.

### Cycle times

- `+cpms/estimateCycleTimes.m`: builds `CycleTimeTable.xlsx` values from the
  first-week logs by joining part entry/exit events per machine and part type.
  It uses robust medians/trimmed means when observations exist.
- `+cpms/defaultCycleTimeTable.m`: fallback cycle-time table. It also preserves
  the hard zero routes for `PT1`/`PT5` at stage 3.

### Release and routing decisions

- `+cpms/generateReleaseCandidates.m`: creates a small set of baseline release
  candidates by varying release intensity. These are the starting plans before
  Digital Model/GA scoring.
- `+cpms/generateReleaseTable.m`: creates a ReleaseTable for the next shift or
  campaign. It uses weekly targets, current WIP, recent production, WIP
  throttling, release spacing, and the course calendar.
- `+cpms/generateRoutingTable.m`: creates the 5x14 routing percentage matrix.
  It balances each stage using cycle time, buffer load, and alarm burden while
  forcing `PT1` and `PT5` to skip stage 3.

### Digital Model scoring and GA training

- `+cpms/selectReleaseWithDigitalModel.m`: the large candidate-selection
  module. It builds GA genomes, generates candidate Release/Routing tables,
  writes/validates DM inputs in the configured Digital Model folder, runs
  weekly or full-horizon scoring through the official course runner by default,
  picks the best candidate, logs production/KPI sheets, and persists GA state
  for the next run. The optional copied `DM_Work` path is diagnostic only.
- `+cpms/runDigitalModelLive.m`: COM-based Tecnomatix Plant Simulation runner.
  It loads the `.spp` model, runs replications, collects output tables, and can
  update the live KPI dashboard. It is useful for diagnostics, but trusted GA
  scoring uses the official p-coded course `dm_run` path by default.
- `+cpms/extractDmScore.m`: converts Digital Model outputs into one scalar
  score. It is aligned to the course KPI contract: it rewards target
  attainment, throughput, PT5 priority, and plan efficiency, while penalizing
  WIP, excess planned release, lead time, daily production variability,
  imbalance, and high machine saturation.

### Writing outputs and safety

- `+cpms/writeDecisionTables.m`: writes `ReleaseTable.xlsx`,
  `RoutingTable.xlsx`, and `CycleTimeTable.xlsx` to the configured decision
  folder. It also writes audit snapshots, backs up existing files when enabled,
  and quarantines unsafe legacy release tables.
- `+cpms/ensureDir.m`: creates a folder if it does not exist.
- `+cpms/firstExistingDir.m`: picks the first folder that exists from a list of
  candidates.
- `+cpms/inferShiftId.m`: infers a shift identifier when one is not supplied.
- `+cpms/mergeStruct.m`: applies config overrides without losing unspecified
  defaults.
- `+cpms/vertcatLoose.m`: vertically concatenates tables even when their
  columns do not perfectly match. This is used for logs/history where new
  fields may appear over time.

### What not to run accidentally

There is no Real System executor in this project. The DSS prepares files that
the Real System can consume later, but it does not call `rs_execute` or advance
the graded Real System. The only external simulator controlled here is the
Digital Model through Tecnomatix COM, and only when
`UseDigitalModelScoring=true`.

## Validation

Run:

```matlab
validate_cpms_outputs('KeepFiles', true);
```

Current validation result:

- Release table passed.
- Routing table passed.
- Cycle-time table passed.
- No Real System run is performed by validation.
- No Tecnomatix run is performed by validation unless you explicitly run the
  Digital Model scoring path separately.
