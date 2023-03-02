//
//  SideWidget.swift
//  SideWidget
//
//  Created by Riley Testut on 6/26/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import CoreData
import SwiftUI
import UIKit
import WidgetKit

import AltSign
import SideStoreCore
import Roxas
import RoxasUIKit
import os.log

struct AppEntry: TimelineEntry {
    var date: Date
    var relevance: TimelineEntryRelevance?

    var app: AppSnapshot?
    var isPlaceholder: Bool = false
}

struct AppSnapshot {
    var name: String
    var bundleIdentifier: String
    var expirationDate: Date
    var refreshedDate: Date

    var tintColor: UIColor?
    var icon: UIImage?
}

extension AppSnapshot {
    // Declared in extension so we retain synthesized initializer.
    init(installedApp: InstalledApp) {
        name = installedApp.name
        bundleIdentifier = installedApp.bundleIdentifier
        expirationDate = installedApp.expirationDate
        refreshedDate = installedApp.refreshedDate

        tintColor = installedApp.storeApp?.tintColor

        let application = ALTApplication(fileURL: installedApp.fileURL)
        icon = application?.icon?.resizing(toFill: CGSize(width: 180, height: 180))
    }
}

struct Provider: IntentTimelineProvider {
    typealias Intent = ViewAppIntent
    typealias Entry = AppEntry

    func placeholder(in _: Context) -> AppEntry {
        AppEntry(date: Date(), app: nil, isPlaceholder: true)
    }

    func getSnapshot(for _: ViewAppIntent, in _: Context, completion: @escaping (AppEntry) -> Void) {
        prepare { result in
            do {
                let context = try result.get()
                let snapshot = InstalledApp.fetchAltStore(in: context).map(AppSnapshot.init)

                let entry = AppEntry(date: Date(), app: snapshot)
                completion(entry)
            } catch {
                os_log(" %@", type: .error , error.localizedDescription)

                let entry = AppEntry(date: Date(), app: nil)
                completion(entry)
            }
        }
    }

    func getTimeline(for configuration: ViewAppIntent, in _: Context, completion: @escaping (Timeline<AppEntry>) -> Void) {
        prepare { result in
            autoreleasepool {
                do {
                    let context = try result.get()

                    let installedApp: InstalledApp?

                    if let identifier = configuration.app?.identifier {
                        let app = InstalledApp.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), identifier),
                                                     in: context)
                        installedApp = app
                    } else {
                        installedApp = InstalledApp.fetchAltStore(in: context)
                    }

                    guard let snapshot = installedApp.map(AppSnapshot.init) else { throw ALTError(.invalidApp) }

                    let currentDate = Calendar.current.startOfDay(for: Date())
                    let numberOfDays = snapshot.expirationDate.numberOfCalendarDays(since: currentDate)

                    // Generate a timeline consisting of one entry per day.
                    var entries: [AppEntry] = []

                    switch numberOfDays {
                    case ..<0:
                        let entry = AppEntry(date: currentDate, relevance: TimelineEntryRelevance(score: 0.0), app: snapshot)
                        entries.append(entry)

                    case 0:
                        let entry = AppEntry(date: currentDate, relevance: TimelineEntryRelevance(score: 1.0), app: snapshot)
                        entries.append(entry)

                    default:
                        // To reduce memory consumption, we only generate entries for the next week. This includes:
                        // * 1 for each day the app is valid (up to 7)
                        // * 1 "0 days remaining"
                        // * 1 "Expired"
                        let numberOfEntries = min(numberOfDays, 7) + 2

                        let appEntries = (0 ..< numberOfEntries).map { dayOffset -> AppEntry in
                            let entryDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: currentDate) ?? currentDate.addingTimeInterval(Double(dayOffset) * 60 * 60 * 24)

                            let daysSinceRefresh = entryDate.numberOfCalendarDays(since: snapshot.refreshedDate)
                            let totalNumberOfDays = snapshot.expirationDate.numberOfCalendarDays(since: snapshot.refreshedDate)

                            let score = (entryDate <= snapshot.expirationDate) ? Float(daysSinceRefresh + 1) / Float(totalNumberOfDays + 1) : 0 // Expired apps have a score of 0.
                            let entry = AppEntry(date: entryDate, relevance: TimelineEntryRelevance(score: score), app: snapshot)
                            return entry
                        }

                        entries.append(contentsOf: appEntries)
                    }

                    let timeline = Timeline(entries: entries, policy: .atEnd)
                    completion(timeline)
                } catch {
                    os_log(" %@", type: .error , error.localizedDescription)

                    let entry = AppEntry(date: Date(), app: nil)
                    let timeline = Timeline(entries: [entry], policy: .atEnd)
                    completion(timeline)
                }
            }
        }
    }

    private func prepare(completion: @escaping (Result<NSManagedObjectContext, Error>) -> Void) {
        DatabaseManager.shared.start { error in
            if let error = error {
                completion(.failure(error))
            } else {
                DatabaseManager.shared.viewContext.perform {
                    completion(.success(DatabaseManager.shared.viewContext))
                }
            }
        }
    }
}

struct HomeScreenWidget: Widget {
    private let kind: String = "AppDetail"

    public var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: ViewAppIntent.self,
                            provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .supportedFamilies([.systemSmall])
        .configurationDisplayName("SideWidget")
        .description("View remaining days until your sideloaded apps expire.")
    }
}

struct TextLockScreenWidget: Widget {
    private let kind: String = "TextLockAppDetail"

    public var body: some WidgetConfiguration {
        if #available(iOSApplicationExtension 16, *) {
            return IntentConfiguration(kind: kind,
                                       intent: ViewAppIntent.self,
                                       provider: Provider()) { entry in
                ComplicationView(entry: entry, style: .text)
            }
            .supportedFamilies([.accessoryCircular])
            .configurationDisplayName("SideWidget (Text)")
            .description("View remaining days until SideStore expires.")
        } else {
            return EmptyWidgetConfiguration()
        }
    }
}

struct IconLockScreenWidget: Widget {
    private let kind: String = "IconLockAppDetail"

    public var body: some WidgetConfiguration {
        if #available(iOSApplicationExtension 16, *) {
            return IntentConfiguration(kind: kind,
                                       intent: ViewAppIntent.self,
                                       provider: Provider()) { entry in
                ComplicationView(entry: entry, style: .icon)
            }
            .supportedFamilies([.accessoryCircular])
            .configurationDisplayName("SideWidget (Icon)")
            .description("View remaining days until SideStore expires.")
        } else {
            return EmptyWidgetConfiguration()
        }
    }
}

//
// struct LockScreenWidget: Widget
// {
//    private let kind: String = "LockAppDetail"
//
//    public var body: some WidgetConfiguration {
//        if #available(iOSApplicationExtension 16, *)
//        {
//            return IntentConfiguration(kind: kind,
//                                       intent: ViewAppIntent.self,
//                                       provider: Provider()) { (entry) in
//                ComplicationView(entry: entry, style: .icon)
//            }
//            .supportedFamilies([.accessoryCircular])
//            .configurationDisplayName("SideWidget")
//            .description("View remaining days until SideStore expires.")
//        }
//        else
//        {
//            return EmptyWidgetConfiguration()
//        }
//    }
// }

@main
struct SideWidgets: WidgetBundle {
    var body: some Widget {
        HomeScreenWidget()
        IconLockScreenWidget()
        TextLockScreenWidget()
    }
}
