# CYBERDINE-SYSTEMS

Shared CPMS Matlab DSS package for the Siemens Tecnomatix Digital Model project.

## Contents

- `CPMS_DSS/` - browsable Matlab DSS source, README, and selected artifacts
- `CPMS_DSS_GitHub_Export.zip` - same package zipped for easy download/share

## Not included

- Tecnomatix `.spp` model files
- course-supplied `dm_config.p` / `dm_run.p`
- Real System files or `rs_execute`
- old debug archives and large generated logs

## Quick start

```matlab
cd('path_to_this_repo/CPMS_DSS');
addpath(pwd);
report = diagnose_cpms_project();
report.Summary
report.Issues
```

To prepare a real-system-style handoff without retraining:

```matlab
result = run_cpms_trained_policy();
```

Inspect the generated Excel files before any manual Real System run.
