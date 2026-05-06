function candidates = generateReleaseCandidates(sysState, logs, kpis, config)
%GENERATERELEASECANDIDATES Build conservative release alternatives.

base = cpms.generateReleaseTable(sysState, logs, kpis, config, 1.0);
candidates = cell(max(1, config.NumReleaseCandidates), 1);
candidates{1} = base;

factors = [0.75, 1.25, 1.5, 0.5, 1.75];
for i = 2:numel(candidates)
    factor = factors(min(i - 1, numel(factors)));
    candidates{i} = cpms.generateReleaseTable(sysState, logs, kpis, config, factor);
end
end
