-- Small, reviewable facts pinned from ordinary GUI captures.  The source
-- NDJSON lives under ignored runtime evidence; this fixture keeps the proof
-- identity available to clean checkouts without committing multi-megabyte logs.
return {
  crossing = {
    sourceSession = "crossing-ui-20260809-0330",
    sequence = 20,
    observedLengthMetres = 74,
    transaction = {
      schemaVersion = 5,
      companyCid = "company:1",
      cost = 27616,
      nodes = {
        { slot = "node:1", position = {
          x = 816.42230224609375, y = 1113.9595947265625, z = 9.1738481521606445,
        } },
        { slot = "node:2", position = {
          x = 853.8541259765625, y = 1133.93896484375, z = 8.9604635238647461,
        } },
        { slot = "node:3", position = {
          x = 883.93280029296875, y = 1130.1104736328125, z = 8.2368545532226563,
        } },
        { slot = "node:4", position = {
          x = 890.1571044921875, y = 1175.40576171875, z = 11.787701606750488,
        } },
      },
      edges = {
        {
          slot = "edge:1", carrier = "track", private = true,
          logicalOwnerCid = "company:1", catenary = true,
          resource = { index = 1, name = "standard.lua" },
          node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
          tangent0 = { x = 29.571842193603516, y = 33.775871276855469,
            z = 0.58251720666885376 },
          tangent1 = { x = 42.518135070800781, y = 5.5192117691040039,
            z = -0.82314634323120117 },
          type = 0, typeIndex = -1,
        },
        {
          slot = "edge:2", carrier = "track", private = true,
          logicalOwnerCid = "company:1", catenary = true,
          resource = { index = 1, name = "standard.lua" },
          node0 = { slot = "node:2" }, node1 = { slot = "node:3" },
          tangent0 = { x = 29.899557113647461, y = 3.8812141418457031,
            z = -0.57885211706161499 },
          tangent1 = { x = 29.293270111083984, y = -11.768837928771973,
            z = -0.80363368988037109 },
          type = 0, typeIndex = -1,
        },
        {
          slot = "edge:3", carrier = "street", private = false,
          logicalOwnerCid = "company:1",
          resource = { index = 22, name = "standard/town_medium_new.lua" },
          node0 = { slot = "node:2" }, node1 = { cid = "node:pre:f98b0bda" },
          tangent0 = { x = -43.255336761474609, y = -49.404640197753906,
            z = -1.3899012804031372 },
          tangent1 = { x = -43.259407043457031, y = -49.409320831298828,
            z = -1.2003086805343628 },
          type = 0, typeIndex = -1,
        },
        {
          slot = "edge:4", carrier = "street", private = false,
          logicalOwnerCid = "company:1",
          resource = { index = 22, name = "standard/town_medium_new.lua" },
          node0 = { cid = "node:pre:f9d20be2" }, node1 = { slot = "node:4" },
          tangent0 = { x = -36.335540771484375, y = -41.501129150390625, z = 0 },
          tangent1 = { x = -36.335514068603516, y = -41.501144409179688,
            z = -2.5214798450469971 },
          type = 0, typeIndex = -1,
        },
        {
          slot = "edge:5", carrier = "street", private = false,
          logicalOwnerCid = "company:1",
          resource = { index = 22, name = "standard/town_medium_new.lua" },
          node0 = { slot = "node:4" }, node1 = { slot = "node:2" },
          tangent0 = { x = -36.304374694824219, y = -41.465576171875,
            z = -2.5193188190460205 },
          tangent1 = { x = -36.304405212402344, y = -41.465545654296875,
            z = -1.1665506362915039 },
          type = 0, typeIndex = -1,
        },
      },
      edgeObjects = { add = {}, retain = {}, remove = {} },
      remove = {
        edges = { "edge:pre:c72a0fc8", "edge:pre:c8510fd0" },
        nodes = { "node:pre:f9fc0be2" },
      },
      digest = "ae34d9d9",
      transactionId = "proposal:ae34d9d9",
    },
  },
  bridges = {
    sourceSession = "station-collateralfix-20260807-111035",
    captures = {
      { digest = "5e25400a", nodes = 11, edges = 11, bridgeEdges = 9,
        bridgeTypeIndex = 4, approximateConnectedLengthMetres = 839.854,
        minimumZ = 1.66453003883362, maximumZ = 14.0108528137207 },
      { digest = "5f1fa1fe", nodes = 12, edges = 12, bridgeEdges = 9,
        bridgeTypeIndex = 4, approximateConnectedLengthMetres = 890.727,
        minimumZ = 0.0999984741210938, maximumZ = 14.0108528137207 },
    },
  },
  cityStations = {
    sourceSession = "station-collateralfix-20260807-111035",
    captures = {
      { sequence = 4, digest = "190d9104", collateralBuildings = 1,
        nodes = 50, edges = 48, x = -1151.15576171875,
        y = -656.8016357421875, z = 41.687255859375 },
      { sequence = 8, digest = "0bd6ec9b", collateralBuildings = 7,
        nodes = 50, edges = 48, x = 933.15606689453125,
        y = 1234.3876953125, z = 10.860562324523926 },
      { sequence = 12, digest = "6e5fed2e", collateralBuildings = 7,
        nodes = 50, edges = 48, x = 1301.22900390625,
        y = 1100.7210693359375, z = 5.8488454818725586 },
    },
  },
}
