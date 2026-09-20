//
//  DirtUITests.swift
//  DirtUITests
//
//  Created by Richard Smith on 7/25/26.
//

import XCTest

final class DirtUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // Dynamic launch coverage deliberately exercises landscape. Reset the
        // ordinary UI tests so their position assertions are order-independent.
        XCUIDevice.shared.orientation = .portrait

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    private func skipOnboardingIfPresented(in app: XCUIApplication) {
        let skip = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Skip", "Skip to map"])
        ).firstMatch
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
        }
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testCueSelectorHierarchy() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_CUES"] = "1"
        app.launch()

        skipOnboardingIfPresented(in: app)

        let cues = app.buttons["navigation-cues"]
        XCTAssertTrue(cues.waitForExistence(timeout: 8))
        cues.tap()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Cue Selector — Essential and Everything"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.descendants(matching: .any)["cue-mode-junctions"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["cue-mode-rally"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["cue-audio-on"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["cue-audio-off"].exists)
    }

    @MainActor
    func testPrimaryMapKeepsViewAndStatusButHidesRideOnlyControls() throws {
        let app = XCUIApplication()
        app.launch()

        skipOnboardingIfPresented(in: app)

        XCTAssertTrue(app.buttons["map-view-mode"].waitForExistence(timeout: 8))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Primary Map Controls — Idle"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.buttons["rider-status"].exists)
        XCTAssertFalse(app.buttons["navigation-cues"].exists)
        XCTAssertFalse(app.buttons["planned-route-overview"].exists)
    }

    @MainActor
    func testFuelPanelOffersReversibleFuelNotificationsControl() throws {
        let app = XCUIApplication()
        app.launch()

        skipOnboardingIfPresented(in: app)

        let route = app.buttons["Route"]
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        route.tap()

        let fuelRange = app.buttons["Fuel range"]
        XCTAssertTrue(fuelRange.waitForExistence(timeout: 8))
        fuelRange.tap()

        let notifications = app.switches["Turn on fuel notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fuel Panel — Fuel Notifications"
        attachment.lifetime = .keepAlways
        add(attachment)

        let original = notifications.value as? String ?? String(describing: notifications.value)
        notifications.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", original),
            object: notifications
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)

        let changedAttachment = XCTAttachment(screenshot: app.screenshot())
        changedAttachment.name = "Fuel Panel — Fuel Notifications Changed"
        changedAttachment.lifetime = .keepAlways
        add(changedAttachment)

        notifications.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", original),
            object: notifications
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
    }

    @MainActor
    func testLongRouteProgressAppearsOnlyAfterWaitingAndOmitsPackCopy() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_ROUTE_PROGRESS"] = "craft"
        app.launch()
        skipOnboardingIfPresented(in: app)
        let progress = app.descendants(matching: .any)["route-progress-toast"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        let notice = NSPredicate(format: "value CONTAINS %@", "10 seconds to over a minute")
        let earlyNotice = XCTNSPredicateExpectation(predicate: notice, object: progress)
        earlyNotice.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [earlyNotice], timeout: 10), .completed)
        let delayedNotice = XCTNSPredicateExpectation(predicate: notice, object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [delayedNotice], timeout: 15), .completed)
        let value = progress.value as? String ?? ""
        XCTAssertTrue(value.contains("10 seconds to over a minute"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("pack"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("download"))
        XCTAssertLessThan(progress.frame.maxY, app.windows.firstMatch.frame.maxY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Long Route Progress — After Twenty Seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRouteProgressShowsCraftHypeCopy() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_ROUTE_PROGRESS"] = "craft"
        app.launch()

        skipOnboardingIfPresented(in: app)

        let progress = app.descendants(matching: .any)["route-progress-toast"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertEqual(progress.label, "Creating the time of your life…")
        let value = progress.value as? String ?? ""
        XCTAssertTrue(value.contains("Scouting roads worth the ride"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("fuel"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("automatic"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("planning"))
        XCTAssertLessThan(
            progress.frame.midX,
            app.windows.firstMatch.frame.midX,
            "Route progress should stay in the upper-left map chrome, not over the planner"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Route Progress — Craft Hype"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFerryRouteIsDistinctAndExplained() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_FERRY"] = "1"
        app.launch()

        skipOnboardingIfPresented(in: app)

        let route = app.buttons["Route"]
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        route.tap()

        let notice = app.descendants(matching: .any)["ferry-route-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Ferry crossing included"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Ferry Route — Crossing and Rider Notice"
        attachment.lifetime = .keepAlways
        add(attachment)

        route.tap()
        XCTAssertTrue(app.buttons["planned-route-overview"].waitForExistence(timeout: 3))

        let mapAttachment = XCTAttachment(screenshot: app.screenshot())
        mapAttachment.name = "Ferry Route — Marine Blue Crossing"
        mapAttachment.lifetime = .keepAlways
        add(mapAttachment)
    }

    @MainActor
    func testPaywallKeepsPurchaseControlsReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_PAYWALL"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["paywall-feature-story"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dirt-first routes"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall-purchase-panel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall-primary-action"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["paywall-plan-com.mayday.dirt.pro.yearly"]
                .waitForExistence(timeout: 8),
            "The DEV StoreKit catalogue must publish the yearly plan"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["paywall-plan-com.mayday.dirt.pro.monthly"].exists,
            "The DEV StoreKit catalogue must publish the monthly plan"
        )
        XCTAssertTrue(app.buttons["Close"].exists)
        XCTAssertFalse(app.buttons["Maybe later"].exists)
        XCTAssertFalse(app.buttons["Skip as tester"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "DIRT PRO — Product Story and Anchored Purchase Panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProfileSupplementaryPanelsAndLayersDismissal() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_PROFILE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Profile"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Close"].exists)
        let profileHeader = app.staticTexts["Profile"].firstMatch.frame
        for title in ["Fuel notifications", "Keep-awake & contribute", "Legal"] {
            let entry = app.buttons[title]
            if !entry.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Close"].exists)
            XCTAssertTrue(done.isHittable)
            let heading = app.staticTexts[title].firstMatch
            XCTAssertGreaterThan(heading.frame.minY, profileHeader.minY)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Profile — " + title
            shot.lifetime = .keepAlways
            add(shot)
            done.tap()
        }
        app.buttons["Fuel notifications"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        let heading = app.staticTexts["Fuel notifications"].firstMatch
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["Legal"].waitForExistence(timeout: 3))
        app.buttons["Layers"].tap()
        XCTAssertTrue(app.staticTexts["Downloaded maps"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Clear All"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Layers — Downloaded Maps"
        shot.lifetime = .keepAlways
        add(shot)
        let handle = app.descendants(matching: .any)["Resize sheet"].firstMatch
        XCTAssertTrue(handle.exists)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertFalse(app.staticTexts["Downloaded maps"].isHittable)
        app.buttons["Group"].tap()
        XCTAssertTrue(app.staticTexts["Groups"].waitForExistence(timeout: 3))
        let groupShot = XCTAttachment(screenshot: app.screenshot())
        groupShot.name = "Groups — Primary Panel"
        groupShot.lifetime = .keepAlways
        add(groupShot)
    }

    @MainActor
    func testPlaceSearchSelectionAndErrors() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_SEARCH"] = "1"
        app.launch()
        let search = app.buttons["Search places"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        let field = app.textFields["placeSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        field.typeText("Porters")
        let result = app.buttons.containing(.staticText, identifier: "Porters Lake").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Search — portrait results and keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        result.tap()
        XCTAssertTrue(app.buttons["Add waypoint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Route here"].isHittable)
        XCTAssertFalse(field.exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Search — place actions"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["Add waypoint"].tap()
        XCTAssertTrue(app.buttons["Plan a route"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Add waypoint"].exists)
        search.tap()
        field.typeText("Unavailable")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 4))
        app.buttons["Clear search"].tap()
        field.typeText("Nothing")
        XCTAssertTrue(app.staticTexts["No places found. Try a nearby town or a fuller address."].waitForExistence(timeout: 4))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(field.exists)
    }

    @MainActor
    func testPlaceSearchLandscapeKeyboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_SEARCH"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        guard XCTWaiter.wait(for: [rotated], timeout: 8) == .completed else {
            throw XCTSkip("Existing simulator did not rotate; landscape requires an unlocked simulator/device check.")
        }
        let search = app.buttons["Search places"]
        let field = app.textFields["placeSearchField"]
        let result = app.buttons.containing(.staticText, identifier: "Porters Lake").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Porters")
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        XCTAssertTrue(result.isHittable)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Search — landscape keyboard"
        landscape.lifetime = .keepAlways
        add(landscape)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(field.exists)
    }

    @MainActor
    func testGlassZoomButtonsDoNotPlaceOrMoveMapPins() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_ZOOM_TOUCH"] = "1"
        app.launch()
        let touches = app.staticTexts["map-touch-count"]
        let zooms = app.staticTexts["zoom-action-count"]
        XCTAssertTrue(touches.waitForExistence(timeout: 8))
        let clearMap = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        clearMap.tap()
        XCTAssertEqual(touches.label, "Map touches: 1", "The underlying map must accept real map taps")
        var expectedZooms = 0
        for standalone in [false, true] {
            if standalone { app.buttons["Show standalone zoom"].tap() }
            for identifier in ["map-zoom-in", "map-zoom-out"] {
                let button = app.buttons[identifier]
                XCTAssertTrue(button.isHittable)
                // Both the glyph and the empty glass around it are the button.
                for offset in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.18, dy: 0.3),
                               CGVector(dx: 0.82, dy: 0.7)] {
                    button.coordinate(withNormalizedOffset: offset).tap()
                    expectedZooms += 1
                    XCTAssertEqual(zooms.label, "Zoom actions: \(expectedZooms)")
                    XCTAssertEqual(touches.label, "Map touches: 1")
                }
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).press(forDuration: 0.8)
                // A held button may activate on release; it must never reach map long-press.
                XCTAssertEqual(touches.label, "Map touches: 1")
                expectedZooms = Int(zooms.label.components(separatedBy: ": ").last ?? "") ?? expectedZooms
            }
        }
        // Use a fresh location: tapping the original marker correctly selects
        // that pin instead of invoking the map's placement callback again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)).tap()
        XCTAssertEqual(touches.label, "Map touches: 2", "Map interaction must remain available outside the buttons")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Glass zoom controls — touch isolation"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testWaypointDragAndZoomWaitForExplicitPinTap() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_ZOOM_TOUCH"] = "1"
        app.launchEnvironment["DIRT_UI_TEST_PIN_PLACEMENT"] = "1"
        app.launch()
        let taps = app.staticTexts["placement-tap-count"]
        let drags = app.staticTexts["pin-drag-count"]
        XCTAssertTrue(taps.waitForExistence(timeout: 8))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).tap()
        let pin = app.buttons["+"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertEqual(taps.label, "Placement taps: 0")
        pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.55)))
        XCTAssertEqual(drags.label, "Pin drags: 1")
        XCTAssertEqual(taps.label, "Placement taps: 0", "Drag release/reselection must not ask to place")
        app.buttons["map-zoom-in"].tap()
        app.buttons["map-zoom-out"].tap()
        XCTAssertEqual(taps.label, "Placement taps: 0", "Zoom must leave placement open")
        pin.tap()
        XCTAssertEqual(taps.label, "Placement taps: 1", "Only tapping the pin requests confirmation")
        print("PLACEMENT_PIN_AFTER_TAP: \(pin.debugDescription)")
        pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        XCTAssertEqual(drags.label, "Pin drags: 2")
        XCTAssertEqual(taps.label, "Placement taps: 1")
        pin.tap()
        XCTAssertEqual(taps.label, "Placement taps: 2")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
