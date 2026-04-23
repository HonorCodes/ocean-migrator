data:extend({
  {
    type = "bool-setting",
    name = "omb-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a"
  },
  {
    type = "double-setting",
    name = "omb-min-evolution",
    setting_type = "runtime-global",
    default_value = 0.50,
    minimum_value = 0,
    maximum_value = 1,
    order = "b"
  },
  {
    type = "int-setting",
    name = "omb-cooldown-minutes",
    setting_type = "runtime-global",
    default_value = 30,
    minimum_value = 1,
    maximum_value = 240,
    order = "c"
  },
  {
    type = "int-setting",
    name = "omb-min-water-tiles",
    setting_type = "runtime-global",
    default_value = 8,
    minimum_value = 2,
    maximum_value = 1024,
    order = "d"
  },
  {
    type = "int-setting",
    name = "omb-min-migration-chunks",
    setting_type = "runtime-global",
    default_value = 3,
    minimum_value = 0,
    maximum_value = 256,
    order = "da"
  },
  {
    type = "int-setting",
    name = "omb-scan-step",
    setting_type = "runtime-global",
    default_value = 4,
    minimum_value = 1,
    maximum_value = 64,
    order = "g"
  },
  {
    type = "int-setting",
    name = "omb-max-samples-per-attempt",
    setting_type = "runtime-global",
    default_value = 24,
    minimum_value = 1,
    maximum_value = 256,
    order = "h"
  },
  {
    type = "int-setting",
    name = "omb-nests-per-beachhead",
    setting_type = "runtime-global",
    default_value = 2,
    minimum_value = 1,
    maximum_value = 12,
    order = "i"
  },
  {
    type = "int-setting",
    name = "omb-max-beachheads-per-surface",
    setting_type = "runtime-global",
    default_value = 20,
    minimum_value = 1,
    maximum_value = 1000,
    order = "j"
  },
  {
    type = "int-setting",
    name = "omb-min-distance-from-player",
    setting_type = "runtime-global",
    default_value = 128,
    minimum_value = 0,
    maximum_value = 4096,
    order = "k"
  },
  {
    type = "bool-setting",
    name = "omb-build-islands",
    setting_type = "runtime-global",
    default_value = false,
    order = "l"
  },
  {
    type = "int-setting",
    name = "omb-landfall-radius",
    setting_type = "runtime-global",
    default_value = 6,
    minimum_value = 1,
    maximum_value = 32,
    order = "la"
  },
  {
    type = "double-setting",
    name = "omb-budget-scaling",
    setting_type = "runtime-global",
    default_value = 1.0,
    minimum_value = 0.1,
    maximum_value = 100.0,
    order = "lb"
  },
  {
    type = "string-setting",
    name = "omb-landfall-tile",
    setting_type = "runtime-global",
    default_value = "auto",
    allowed_values = {
      "auto",
      "grass-1",
      "dirt-7",
      "dry-dirt",
      "sand-1",
      "landfill"
    },
    order = "m"
  },
  {
    type = "bool-setting",
    name = "omb-use-water-spitters",
    setting_type = "runtime-global",
    default_value = true,
    order = "n"
  },
  {
    type = "bool-setting",
    name = "omb-chart-beachheads",
    setting_type = "runtime-global",
    default_value = true,
    order = "o"
  },
  {
    type = "bool-setting",
    name = "omb-notify",
    setting_type = "runtime-global",
    default_value = true,
    order = "p"
  },
  {
    type = "bool-setting",
    name = "omb-debug",
    setting_type = "runtime-global",
    default_value = false,
    order = "q"
  },
  {
    type = "int-setting",
    name = "omb-budget-max",
    setting_type = "runtime-global",
    default_value = 10000,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "r"
  },
  {
    type = "int-setting",
    name = "omb-budget-gain-per-minute",
    setting_type = "runtime-global",
    default_value = 100,
    minimum_value = 0,
    maximum_value = 100000,
    order = "s"
  },
  {
    type = "int-setting",
    name = "omb-budget-base-cost",
    setting_type = "runtime-global",
    default_value = 1000,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "t"
  },
  {
    type = "int-setting",
    name = "omb-budget-water-cost-per-100",
    setting_type = "runtime-global",
    default_value = 250,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "u"
  },
  {
    type = "int-setting",
    name = "omb-budget-cost-per-nest",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "v"
  }
})
