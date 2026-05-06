function cycleTimes = defaultCycleTimeTable(config)
%DEFAULTCYCLETIMETABLE Build the validated CPMS CycleTimeTable schema.

if nargin < 1 || ~isfield(config, 'Machines')
    machines = "M" + string(1:14);
else
    machines = string(config.Machines(:));
end

ref = [ ...
     800  740  630  680  700;
     660  710  770  695  625;
     700  700  755  640  665;
     905  795  810  850  870;
     880  800  700  905  780;
     800  810  850  885  885;
     960 1000  900  910 1035;
       0 1050  950 1050    0;
       0 1020 1030 1180    0;
       0 1150 1050 1300    0;
     900 1020  950  970  910;
     950  935  930 1000  980;
    1025  940  965  985  990;
     955 1000 1000  980  900];

parts = {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'};
cycleTimes = array2table(ref, 'VariableNames', parts);
cycleTimes = addvars(cycleTimes, machines(:), 'Before', 1, 'NewVariableNames', 'M');
end
