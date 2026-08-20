@testset "set_value! stores a matching unit unchanged" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test bus.base_voltage == 138.0
end

@testset "set_value! assigns units that have no conversion factor" begin
    # to_default is 0.0 for Angle and null for pu bases, so no factor exists.
    # Assignment must still work when source and target already agree.
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :angle, 0.3, "rad")
    @test bus.angle == 0.3

    line = PFP.PO.Line()
    PFP.set_value!(line, :r, 0.003, "pu")
    @test line.r == 0.003
end

@testset "set_value! converts within a quantity" begin
    storage = PFP.PO.EnergyReservoirStorage()
    PFP.set_value!(storage, :storage_capacity, 3600.0, "MJ")
    @test storage.storage_capacity ≈ 1.0

    converter = PFP.PO.InterconnectingConverter()
    PFP.set_value!(converter, :dc_current, 1.5, "kA")
    @test converter.dc_current ≈ 1500.0
end

@testset "set_value! rejects a cross-quantity conversion" begin
    bus = PFP.PO.ACBus()
    @test_throws IS.DataFormatError PFP.set_value!(bus, :base_voltage, 138.0, "MW")

    gen = PFP.PO.ThermalStandard()
    @test_throws IS.DataFormatError PFP.set_value!(gen, :base_power, 100.0, "MWh")
end

@testset "set_value! converts degrees to radians" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :angle, 180.0, "deg")
    @test bus.angle ≈ pi
    PFP.set_value!(bus, :angle, 0.0, "deg")
    @test bus.angle == 0.0
end

@testset "a pu property converts from the unit its base is declared in" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    PFP.set_value!(bus, :magnitude, 141.45, "kV")
    @test bus.magnitude ≈ 1.025

    PFP.set_value!(bus, :magnitude, 1.0, "pu")
    @test bus.magnitude == 1.0
end

@testset "a compound pu property converts every member onto the base" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    PFP.set_value!(bus, :voltage_limits, (min = 131.1, max = 144.9), "kV")
    @test bus.voltage_limits.min ≈ 0.95
    @test bus.voltage_limits.max ≈ 1.05
end

@testset "converting onto an unset base names the base property" begin
    bus = PFP.PO.ACBus()
    @test_throws IS.DataFormatError PFP.set_value!(bus, :magnitude, 141.45, "kV")
end

@testset "a non-positive base is rejected rather than stored as Inf or NaN" begin
    # PSS/E writes BASKV = 0.0 for buses with no specified base.
    zero_base = PFP.PO.ACBus()
    PFP.set_value!(zero_base, :base_voltage, 0.0, "kV")
    @test_throws IS.DataFormatError PFP.set_value!(zero_base, :magnitude, 138.0, "kV")
    @test_throws IS.DataFormatError PFP.set_value!(zero_base, :magnitude, 0.0, "kV")
    @test_throws IS.DataFormatError PFP.set_value!(
        zero_base,
        :voltage_limits,
        (min = 131.1, max = 144.9),
        "kV",
    )

    negative_base = PFP.PO.ACBus()
    PFP.set_value!(negative_base, :base_voltage, -138.0, "kV")
    @test_throws IS.DataFormatError PFP.set_value!(negative_base, :magnitude, 138.0, "kV")
end

@testset "get_value rejects a non-positive base" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 0.0, "kV")
    PFP.set_value!(bus, :magnitude, 1.0, "pu")
    @test_throws IS.DataFormatError PFP.get_value(bus, :magnitude, "kV")
end

@testset "get_value onto an unset base names the base property" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :magnitude, 1.025, "pu")
    @test_throws IS.DataFormatError PFP.get_value(bus, :magnitude, "kV")
end

@testset "get_value expresses a pu value in the base's unit" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    PFP.set_value!(bus, :magnitude, 1.025, "pu")
    @test PFP.get_value(bus, :magnitude) == 1.025
    @test PFP.get_value(bus, :magnitude, "kV") ≈ 141.45
end

@testset "the base mechanism is not ACBus-specific" begin
    source = PFP.PO.Source()
    PFP.set_value!(source, :base_voltage, 230.0, "kV")
    PFP.set_value!(source, :internal_voltage, 234.6, "kV")
    @test source.internal_voltage ≈ 1.02
end

@testset "set_value! rejects units absent from the vocabulary" begin
    gen = PFP.PO.ThermalStandard()
    @test_throws IS.DataFormatError PFP.set_value!(gen, :base_power, 100_000.0, "kW")
end

@testset "arity enforces the unit rule in both directions" begin
    bus = PFP.PO.ACBus()
    @test_throws IS.DataFormatError PFP.set_value!(bus, :name, "Abel", "kV")
    @test_throws IS.DataFormatError PFP.set_value!(bus, :base_voltage, 138.0)

    PFP.set_value!(bus, :name, "Abel")
    PFP.set_value!(bus, :available, true)
    PFP.set_value!(bus, :number, 101)
    @test bus.name == "Abel"
    @test bus.available
    @test bus.number == 101
end

@testset "set_value! runs the generated property validation" begin
    bus = PFP.PO.ACBus()
    @test_throws Exception PFP.set_value!(bus, :bustype, "Ref")
    PFP.set_value!(bus, :bustype, "REF")
    @test bus.bustype == "REF"
end

@testset "compound properties take the unit at object level" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :voltage_limits, (min = 0.95, max = 1.05), "pu")
    @test bus.voltage_limits.min == 0.95
    @test bus.voltage_limits.max == 1.05

    gen = PFP.PO.ThermalStandard()
    PFP.set_value!(gen, :active_power_limits, (min = 15.2, max = 76.0), "MW")
    @test gen.active_power_limits.min == 15.2
    @test gen.active_power_limits.max == 76.0

    PFP.set_value!(gen, :ramp_limits, (up = 3.0, down = 3.0), "MW/min")
    @test gen.ramp_limits.up == 3.0
    @test gen.ramp_limits.down == 3.0

    line = PFP.PO.Line()
    PFP.set_value!(line, :b, (from = 0.0225, to = 0.0225), "pu")
    @test line.b.from == 0.0225
end

@testset "compound properties convert every member" begin
    line = PFP.PO.Line()
    PFP.set_value!(line, :angle_limits, (min = -30.0, max = 30.0), "deg")
    @test line.angle_limits.min ≈ -pi / 6
    @test line.angle_limits.max ≈ pi / 6
end

@testset "discriminated units are read off the instance" begin
    line = PFP.PO.TwoTerminalLCCLine()
    PFP.set_value!(line, :parameter_units, "NATURAL_UNITS")
    PFP.set_value!(line, :r, 5.0, "ohm")
    @test line.r == 5.0

    other = PFP.PO.TwoTerminalLCCLine()
    PFP.set_value!(other, :parameter_units, "COMPONENT_BASE")
    @test_throws IS.DataFormatError PFP.set_value!(other, :r, 5.0, "ohm")
    PFP.set_value!(other, :r, 0.01, "pu")
    @test other.r == 0.01
end

@testset "get_value returns the stored value and converts on request" begin
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test PFP.get_value(bus, :base_voltage) == 138.0
    @test PFP.get_value(bus, :base_voltage, "kV") == 138.0
    @test_throws IS.DataFormatError PFP.get_value(bus, :base_voltage, "MW")

    storage = PFP.PO.EnergyReservoirStorage()
    PFP.set_value!(storage, :storage_capacity, 1.0, "MWh")
    @test PFP.get_value(storage, :storage_capacity, "MJ") ≈ 3600.0
end

@testset "operational time is minutes, and the vocabulary has no hour" begin
    gen = PFP.PO.ThermalStandard()
    PFP.set_value!(gen, :time_limits, (up = 120.0, down = 60.0), "min")
    @test gen.time_limits.up == 120.0
    @test gen.time_limits.down == 60.0

    reserve = PFP.PO.OnlineReserve()
    PFP.set_value!(reserve, :time_frame, 60.0, "min")
    @test reserve.time_frame == 60.0
    @test_throws IS.DataFormatError PFP.set_value!(reserve, :sustained_time, 1.0, "h")
end
