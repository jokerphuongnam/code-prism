import Foundation

struct TypeModuleResolver {

    let projectTypes: Set<String>
    let projectTypeToTarget: [String: String]

    init(symbols: [SymbolInfo]) {
        let typeFlavors: Set<SymbolFlavor> = [.struct, .class, .enum, .actor, .protocol]
        var types = Set<String>()
        var typeTargets = [String: String]()
        for sym in symbols where typeFlavors.contains(sym.flavor) {
            types.insert(sym.name)
            if let t = sym.targetName { typeTargets[sym.name] = t }
        }
        self.projectTypes = types
        self.projectTypeToTarget = typeTargets
    }

    func resolveModules(for typeNames: [String]?) -> [String]? {
        guard let typeNames, !typeNames.isEmpty else { return nil }
        var modules = Set<String>()
        for typeName in typeNames {
            if let target = projectTypeToTarget[typeName] {
                modules.insert(target)
            } else if let framework = Self.systemTypeMap[typeName] {
                modules.insert(framework)
            }
        }
        return modules.isEmpty ? nil : modules.sorted()
    }

    private static let systemTypeMap: [String: String] = {
        var map = [String: String]()
        let uikit = [
            "UIApplication", "UIViewController", "UIView", "UITableView", "UICollectionView",
            "UINavigationController", "UITabBarController", "UIWindow", "UIScene", "UISceneSession",
            "UISceneConfiguration", "UISceneConnectionOptions", "UIScreen", "UIColor", "UIImage",
            "UIFont", "UILabel", "UIButton", "UITextField", "UITextView", "UIStackView",
            "UIScrollView", "UIImageView", "UIAlertController", "UIStoryboard", "UITableViewCell",
            "UICollectionViewCell", "UIGestureRecognizer", "UITapGestureRecognizer",
            "UISwipeGestureRecognizer", "UIApplication", "UIResponder", "UIControl",
            "UIBarButtonItem", "UIToolbar", "UISearchBar", "UIPageViewController",
            "UISplitViewController", "UISwitch", "UISlider", "UIProgressView",
            "UIActivityIndicatorView", "UIPickerView", "UIDatePicker",
        ]
        for t in uikit { map[t] = "UIKit" }

        let foundation = [
            "NSObject", "NSCoder", "NSRegularExpression", "NSAttributedString",
            "NSMutableAttributedString", "NSPredicate", "NSSortDescriptor", "NSCache",
            "NSLock", "NSRecursiveLock", "NSCondition", "NSNotification",
            "JSONDecoder", "JSONEncoder", "PropertyListDecoder", "PropertyListEncoder",
            "URLSession", "URLRequest", "URLResponse", "HTTPURLResponse",
            "FileManager", "ProcessInfo", "Bundle", "UserDefaults", "NotificationCenter",
            "Timer", "DateFormatter", "NumberFormatter", "Calendar", "Locale",
            "TimeZone", "UUID", "Measurement", "UnitLength",
        ]
        for t in foundation { map[t] = "Foundation" }

        let swiftui = [
            "View", "App", "Scene", "WindowGroup", "NavigationView", "NavigationStack",
            "NavigationLink", "List", "ForEach", "VStack", "HStack", "ZStack",
            "Text", "Image", "Button", "Toggle", "Slider", "Stepper", "Picker",
            "DatePicker", "ColorPicker", "TextField", "TextEditor", "SecureField",
            "Form", "Section", "Group", "ScrollView", "LazyVStack", "LazyHStack",
            "LazyVGrid", "LazyHGrid", "TabView", "Sheet", "Alert",
            "EnvironmentValues", "Environment", "EnvironmentObject", "State",
            "Binding", "ObservedObject", "StateObject", "Published", "ObservableObject",
            "ViewModifier", "Shape", "Path", "GeometryReader", "Color", "Font",
            "AnyView", "EmptyView", "Spacer", "Divider",
        ]
        for t in swiftui { map[t] = "SwiftUI" }

        let combine = [
            "Publisher", "Subscriber", "Subject", "PassthroughSubject", "CurrentValueSubject",
            "AnyCancellable", "Cancellable", "AnyPublisher",
        ]
        for t in combine { map[t] = "Combine" }

        let coredata = [
            "NSManagedObject", "NSManagedObjectContext", "NSPersistentContainer",
            "NSFetchRequest", "NSFetchedResultsController", "NSEntityDescription",
        ]
        for t in coredata { map[t] = "CoreData" }

        return map
    }()
}
