function shiftId = inferShiftId(config)
%INFERSHIFTID Infer a shift id from the current clock.

shiftLength = max(1, config.ShiftLengthHours);
nowValue = datetime('now');
shiftId = floor(hours(timeofday(nowValue)) / shiftLength) + 1;
end
