function kpis = computeKpis(sysState, logs, config)
%COMPUTEKPIS Compute required and useful optional KPIs from RS outputs.

wip = cpms.computeWip(sysState, config);
production = cpms.computeProduction(logs, config);
leadTime = cpms.computeLeadTimes(logs);
saturation = cpms.computeMachineSaturation(logs, config);

targetTotal = sum(config.TargetByPart.TargetQty, 'omitnan') / 10;
if targetTotal <= 0
    planEffShift = NaN;
else
    planEffShift = production.CumProdShift / targetTotal;
end

kpis = struct();
kpis.WIP = wip.Total;
kpis.WIPByPart = wip.ByPart;
kpis.CumProdShift = production.CumProdShift;
kpis.CumProdByPart = production.ByPart;
kpis.CumProdTotal = production.CumProdTotal;
kpis.CumProdTotalByPart = production.TotalByPart;
kpis.SigmaCumProd = production.SigmaCumProd;
kpis.PlanEffShift = planEffShift;
kpis.AvLeadTime = leadTime.AvLeadTime;
kpis.LeadTimeByPart = leadTime.ByPart;
kpis.ThroughputByPart = production.ThroughputByPart;
kpis.SaturationByMachine = saturation.ByMachine;
kpis.LastEventTime = production.LastEventTime;
kpis.ShiftStart = production.ShiftStart;
kpis.ShiftEnd = production.ShiftEnd;
end
