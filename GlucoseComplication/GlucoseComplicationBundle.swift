//
//  GlucoseComplicationBundle.swift
//  GlucoseComplication
//
//  Created by Aleksandr Kovalko on 11. 10. 2026..
//

import WidgetKit
import SwiftUI

@main
struct GlucoseComplicationBundle: WidgetBundle {
    var body: some Widget {
        GlucoseComplication()
        ChartComplication()
        InsulinComplication()
        CarbsComplication()
    }
}
