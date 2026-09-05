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
    func testFuelPanelOffersReversibleAutomaticPlanningControl() throws {
        let app = XCUIApplication()
        app.launch()

        skipOnboardingIfPresented(in: app)

        let route = app.buttons["Route"]
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        route.tap()

        let fuelRange = app.buttons["Fuel range"]
        XCTAssertTrue(fuelRange.waitForExistence(timeout: 8))
        fuelRange.tap()

        let automatic = app.switches["Automatic fuel planning"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fuel Panel — Automatic Planning"
        attachment.lifetime = .keepAlways
        add(attachment)

        let original = automatic.value as? String ?? String(describing: automatic.value)
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", original),
            object: automatic
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)

        let changedAttachment = XCTAttachment(screenshot: app.screenshot())
        changedAttachment.name = "Fuel Panel — Automatic Planning Changed"
        changedAttachment.lifetime = .keepAlways
        add(changedAttachment)

        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", original),
            object: automatic
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
    }

    @MainActor
    func testRouteProgressExplainsThatFuelPlanningIsOff() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_ROUTE_PROGRESS"] = "fuel-off"
        app.launch()

        skipOnboardingIfPresented(in: app)

        let progress = app.descendants(matching: .any)["route-progress-toast"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertEqual(progress.label, "Creating route")
        XCTAssertTrue((progress.value as? String)?.contains(
            "Fuel planning is off · Calculating distance"
        ) == true)
        XCTAssertLessThan(
            progress.frame.midX,
            app.windows.firstMatch.frame.midX,
            "Route progress should stay in the upper-left map chrome, not over the planner"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Route Progress — Fuel Planning Off"
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
    func testProfileIsAFullScreenDestination() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DIRT_UI_TEST_PROFILE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Profile"].waitForExistence(timeout: 5))
        let close = app.buttons["Close"]
        XCTAssertTrue(close.exists)
        let route = app.buttons["Route"]
        XCTAssertFalse(route.isHittable, "The full-screen Profile destination must block interaction with the map dock")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Profile — Full-screen Destination"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
