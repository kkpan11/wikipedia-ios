import UIKit
import WMF
import CocoaLumberjackSwift
import Components
import WKData

class ExploreViewController: ColumnarCollectionViewController2, ExploreCardViewControllerDelegate, UISearchBarDelegate, CollectionViewUpdaterDelegate, ImageScaleTransitionProviding, DetailTransitionSourceProviding, MEPEventsProviding {

    public var presentedContentGroupKey: String?
    public var shouldRestoreScrollPosition = false

    @objc public weak var notificationsCenterPresentationDelegate: NotificationsCenterPresentationDelegate?
    @objc public weak var settingsPresentationDelegate: SettingsPresentationDelegate?
    
    private weak var imageRecommendationsViewModel: WKImageRecommendationsViewModel?

    // MARK: - UIViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        layoutManager.register(ExploreCardCollectionViewCell.self, forCellWithReuseIdentifier: ExploreCardCollectionViewCell.identifier, addPlaceholder: true)

        setupNavigationBar()
        updateNotificationsCenterButton()
        updateSettingsButton()

        isRefreshControlEnabled = true
        collectionView.refreshControl?.layer.zPosition = 0

        title = CommonStrings.exploreTabTitle

        NotificationCenter.default.addObserver(self, selector: #selector(exploreFeedPreferencesDidSave(_:)), name: NSNotification.Name.WMFExploreFeedPreferencesDidSave, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(articleDidChange(_:)), name: NSNotification.Name.WMFArticleUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(articleDeleted(_:)), name: NSNotification.Name.WMFArticleDeleted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pushNotificationBannerDidDisplayInForeground(_:)), name: .pushNotificationBannerDidDisplayInForeground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(viewContextDidReset(_:)), name: NSNotification.Name.WMFViewContextDidReset, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(databaseHousekeeperDidComplete), name: .databaseHousekeeperDidComplete, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc var isGranularUpdatingEnabled: Bool = true {
        didSet {
            collectionViewUpdater?.isGranularUpdatingEnabled = isGranularUpdatingEnabled
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startMonitoringReachabilityIfNeeded()
        showOfflineEmptyViewIfNeeded()
        imageScaleTransitionView = nil
        detailTransitionSourceRect = nil
        logFeedImpressionAfterDelay()
        dataStore.remoteNotificationsController.loadNotifications(force: false)
#if UITEST
        presentUITestHelperController()
#endif
        if !UIAccessibility.isVoiceOverRunning {
            presentImageRecommendationsFeatureAnnouncementIfNeeded()
        }
    }
    
    override func viewWillHaveFirstAppearance(_ animated: Bool) {
        super.viewWillHaveFirstAppearance(animated)
        setupFetchedResultsController()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        
        super.viewWillAppear(animated)
        isGranularUpdatingEnabled = true
        restoreScrollPositionIfNeeded()

        // Terrible hack to make back button text appropriate for iOS 14 - need to set the title on `WMFAppViewController`. For all app tabs, this is set in `viewWillAppear`.
        (parent as? WMFAppViewController)?.navigationItem.backButtonTitle = title
    }

    func presentUITestHelperController() {
        let viewController = UITestHelperViewController(theme: theme)
        present(viewController, animated: false)
    }

    private func restoreScrollPositionIfNeeded() {
        guard
            shouldRestoreScrollPosition,
            let presentedContentGroupKey = presentedContentGroupKey,
            let contentGroup = fetchedResultsController?.fetchedObjects?.first(where: { $0.key == presentedContentGroupKey }),
            let indexPath = fetchedResultsController?.indexPath(forObject: contentGroup)
        else {
            return
        }
        collectionView.scrollToItem(at: indexPath, at: [], animated: false)
        self.shouldRestoreScrollPosition = false
        self.presentedContentGroupKey = nil
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        dataStore.feedContentController.dismissCollapsedContentGroups()
        stopMonitoringReachability()
        isGranularUpdatingEnabled = false
    }
    
    @objc private func databaseHousekeeperDidComplete() {
        DispatchQueue.main.async {
            self.refresh()
        }
    }
    
    func setupNavigationBar() {
        navigationItem.titleView = titleView
        navigationController?.navigationBar.prefersLargeTitles = false
        if #available(iOS 17.0, *) {
            navigationItem.largeTitleDisplayMode = .inline
        } else {
            // Fallback on earlier versions
        }
        navigationController?.hidesBarsOnSwipe = true
        navigationItem.hidesSearchBarWhenScrolling = false
        if #available(iOS 16.0, *) {
            navigationItem.preferredSearchBarPlacement = .stacked
        } else {
            // Fallback on earlier versions
        }
        
        let searchViewController = SearchViewController()
        searchViewController.dataStore = dataStore
        searchViewController.delegatesSearchTermSelection = true
        searchViewController.searchTermSelectDelegate = self
        let search = UISearchController(searchResultsController: searchViewController)
        search.searchResultsUpdater = self
        search.searchBar.searchBarStyle = .minimal
        search.searchBar.placeholder = WMFLocalizedString("search-field-placeholder-text", value: "Search Wikipedia", comment: "Search field placeholder text")
        search.showsSearchResultsController = true
        // definesPresentationContext = true
        navigationItem.searchController = search
    }

    @objc func updateNotificationsCenterButton() {
        if self.dataStore.authenticationManager.isLoggedIn {
            let numberOfUnreadNotifications = try? dataStore.remoteNotificationsController.numberOfUnreadNotifications()
            let hasUnreadNotifications = numberOfUnreadNotifications?.intValue ?? 0 != 0
            let bellImage = BarButtonImageStyle.notificationsButtonImage(theme: theme, indicated: hasUnreadNotifications)
            let notificationsBarButton = UIBarButtonItem(image: bellImage, style: .plain, target: self, action: #selector(userDidTapNotificationsCenter))
            notificationsBarButton.accessibilityLabel = hasUnreadNotifications ? CommonStrings.notificationsCenterBadgeTitle : CommonStrings.notificationsCenterTitle
            navigationItem.leftBarButtonItem = notificationsBarButton
        } else {
            navigationItem.leftBarButtonItem = nil
        }
    }
    
    func updateSettingsButton() {
        
        let settingsBarButtonItem = UIBarButtonItem(image: BarButtonImageStyle.settingsButtonImage(theme: theme), style: .plain, target: self, action: #selector(userDidTapSettings))
        settingsBarButtonItem.accessibilityLabel = CommonStrings.settingsTitle
        navigationItem.rightBarButtonItem = settingsBarButtonItem
    }
    
    // MARK: - NavBar
    
    @objc func scrollToTop() {
        navigationController?.setNavigationBarHidden(false, animated: true)
        // TODO: Fix
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: 0 - collectionView.contentInset.top), animated: true)
    }
    
    @objc func titleBarButtonPressed(_ sender: UIButton?) {
        scrollToTop()
    }
    
    @objc public var titleButton: UIView {
        return titleView
    }
    
    lazy var longTitleButton: UIButton = {
        let longTitleButton = UIButton(type: .custom)
        var deprecatedLongTitleButton = longTitleButton as DeprecatedButton
        deprecatedLongTitleButton.deprecatedAdjustsImageWhenHighlighted = true
        longTitleButton.setImage(UIImage(named: "wikipedia"), for: .normal)
        longTitleButton.sizeToFit()
        longTitleButton.addTarget(self, action: #selector(titleBarButtonPressed), for: .touchUpInside)
        longTitleButton.isAccessibilityElement = false
        return longTitleButton
    }()
    
    lazy var titleView: UIView = {
        let titleView = UIView(frame: longTitleButton.bounds)
        titleView.addSubview(longTitleButton)
        titleView.isAccessibilityElement = false
        return titleView
    }()

    @objc func userDidTapSettings() {
        AppInteractionFunnel.shared.logSettingsDidTapSettingsIcon()
     
        settingsPresentationDelegate?.userDidTapSettings(from: self)

    }
    
    open override func refresh() {
        updateFeedSources(with: nil, userInitiated: true) {
        }
    }
    
    // MARK: - Scroll
    
    var isLoadingOlderContent: Bool = false
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        guard !isLoadingOlderContent else {
            return
        }
        
        let ratio: CGFloat = scrollView.contentOffset.y / (scrollView.contentSize.height - scrollView.bounds.size.height)
        if ratio < 0.8 {
            return
        }
        
        let lastSectionIndex = numberOfSectionsInExploreFeed - 1
        guard lastSectionIndex >= 0 else {
            return
        }

        let lastItemIndex = numberOfItemsInSection(lastSectionIndex) - 1
        guard lastItemIndex >= 0 else {
            return
        }
        
        guard let lastGroup = group(at: IndexPath(item: lastItemIndex, section: lastSectionIndex)) else {
            return
        }
        let now = Date()
        let midnightUTC: Date = (now as NSDate).wmf_midnightUTCDateFromLocal
        guard let lastGroupMidnightUTC = lastGroup.midnightUTCDate else {
            return
        }
        
        // TODO: Investigate why this isn't paging
        let calendar = NSCalendar.wmf_gregorian()
        let days: Int = calendar?.wmf_days(from: lastGroupMidnightUTC, to: midnightUTC) ?? 0
        guard days < Int(WMFExploreFeedMaximumNumberOfDays) else {
            return
        }
        
        guard let nextOldestDate: Date = calendar?.date(byAdding: .day, value: -1, to: lastGroupMidnightUTC, options: .matchStrictly) else {
            return
        }
        
        isLoadingOlderContent = true
        updateFeedSources(with: (nextOldestDate as NSDate).wmf_midnightLocalDateForEquivalentUTC, userInitiated: false) {
            self.isLoadingOlderContent = false
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        logFeedImpressionAfterDelay()
    }

    // MARK: - Event logging

    private func logFeedImpressionAfterDelay() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(logFeedImpression), object: nil)
        perform(#selector(logFeedImpression), with: self, afterDelay: 3)
    }

    @objc private func logFeedImpression() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let group = group(at: indexPath), group.undoType == .none, let itemFrame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                continue
            }
            // TODO: Test this.
            let navBarVisibleHeight = CGFloat(0) // navigationBar.visibleHeight
            let visibleRectOrigin = CGPoint(x: collectionView.contentOffset.x, y: collectionView.contentOffset.y + navBarVisibleHeight)
            let visibleRectSize = view.layoutMarginsGuide.layoutFrame.size
            let itemCenter = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
            let visibleRect = CGRect(origin: visibleRectOrigin, size: visibleRectSize)
            let isUnobstructed = visibleRect.contains(itemCenter)
            guard isUnobstructed else {
                continue
            }
        }
    }
    
    // MARK: - Search
    
    @objc func ensureWikipediaSearchIsShowing() {
        navigationController?.setNavigationBarHidden(false, animated: true)
    }

    // MARK: - UISearchBarDelegate
    
    func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool {
        let searchActivity = NSUserActivity.wmf_searchView()
        NotificationCenter.default.post(name: .WMFNavigateToActivity, object: searchActivity)
        return false
    }
    
    // MARK: - State
    
    @objc var dataStore: MWKDataStore!
    private var fetchedResultsController: NSFetchedResultsController<WMFContentGroup>?
    private var collectionViewUpdater: CollectionViewUpdater<WMFContentGroup>?
    
    private var wantsDeleteInsertOnNextItemUpdate: Bool = false

    private func setupFetchedResultsController() {
        let fetchRequest: NSFetchRequest<WMFContentGroup> = WMFContentGroup.fetchRequest()
        let today = NSDate().wmf_midnightUTCDateFromLocal as Date
        let oldestDate = Calendar.current.date(byAdding: .day, value: -WMFExploreFeedMaximumNumberOfDays, to: today) ?? today
        fetchRequest.predicate = NSPredicate(format: "isVisible == YES && (placement == NULL || placement == %@) && midnightUTCDate >= %@", "feed", oldestDate as NSDate)
        fetchRequest.sortDescriptors = dataStore.feedContentController.exploreFeedSortDescriptors()
        let frc = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: dataStore.viewContext, sectionNameKeyPath: "midnightUTCDate", cacheName: nil)
        fetchedResultsController = frc
        let updater = CollectionViewUpdater(fetchedResultsController: frc, collectionView: collectionView)
        collectionViewUpdater = updater
        updater.delegate = self
        updater.isSlidingNewContentInFromTheTopEnabled = true
        updater.performFetch()
    }
    
    private func group(at indexPath: IndexPath) -> WMFContentGroup? {
        guard let frc = fetchedResultsController, frc.isValidIndexPath(indexPath) else {
            return nil
        }
        return frc.object(at: indexPath)
    }
    
    private func groupKey(at indexPath: IndexPath) -> WMFInMemoryURLKey? {
        return group(at: indexPath)?.inMemoryKey
    }
    
    lazy var saveButtonsController: SaveButtonsController = {
        let sbc = SaveButtonsController(dataStore: dataStore)
        sbc.delegate = self
        return sbc
    }()
    
    var numberOfSectionsInExploreFeed: Int {
        guard let sections = fetchedResultsController?.sections else {
            return 0
        }
        return sections.count
    }
    
    func numberOfItemsInSection(_ section: Int) -> Int {
        guard let sections = fetchedResultsController?.sections, sections.count > section else {
            return 0
        }
        return sections[section].numberOfObjects
    }
    
    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        return numberOfSectionsInExploreFeed
    }
    
    private func resetRefreshControl() {
        guard let refreshControl = collectionView.refreshControl,
            refreshControl.isRefreshing else {
            return
        }
        refreshControl.endRefreshing()
    }
    
    lazy var reachabilityNotifier: ReachabilityNotifier = {
        let notifier = ReachabilityNotifier(Configuration.current.defaultSiteDomain) { [weak self] (reachable, flags) in
            if reachable {
                DispatchQueue.main.async {
                    self?.updateFeedSources(userInitiated: false)
                }
            } else {
                DispatchQueue.main.async {
                    self?.showOfflineEmptyViewIfNeeded()

                }
            }
        }
        return notifier
    }()
    
    private func stopMonitoringReachability() {
        reachabilityNotifier.stop()
    }
    
    private func startMonitoringReachabilityIfNeeded() {
        guard numberOfSectionsInExploreFeed == 0 else {
            stopMonitoringReachability()
            return
        }
        reachabilityNotifier.start()
    }
    
    private func showOfflineEmptyViewIfNeeded() {
        guard isViewLoaded && fetchedResultsController != nil else {
            return
        }
        
        guard numberOfSectionsInExploreFeed == 0 else {
            wmf_hideEmptyView()
            return
        }
        
        guard !wmf_isShowingEmptyView() else {
            return
        }
        
        guard !reachabilityNotifier.isReachable else {
            return
        }
        
        resetRefreshControl()
        wmf_showEmptyView(of: .noFeed, theme: theme, frame: view.bounds)
    }
    
    var isLoadingNewContent = false

    @objc(updateFeedSourcesWithDate:userInitiated:completion:)
    public func updateFeedSources(with date: Date? = nil, userInitiated: Bool, completion: @escaping () -> Void = { }) {
        assert(Thread.isMainThread)
        guard !isLoadingNewContent else {
            completion()
            return
        }
        isLoadingNewContent = true
        if date == nil, let refreshControl = collectionView.refreshControl, !refreshControl.isRefreshing {
            refreshControl.beginRefreshing()
            if numberOfSectionsInExploreFeed == 0 {
                scrollToTop()
            }
        }
        self.dataStore.feedContentController.updateFeedSources(with: date, userInitiated: userInitiated) {
            DispatchQueue.main.async {
                self.isLoadingNewContent = false
                self.resetRefreshControl()
                if date == nil {
                    self.startMonitoringReachabilityIfNeeded()
                    self.showOfflineEmptyViewIfNeeded()
                }
                completion()
            }
        }
    }
    
    override func contentSizeCategoryDidChange(_ notification: Notification?) {
        layoutCache.reset()
        super.contentSizeCategoryDidChange(notification)
    }
    
    // MARK: - ImageScaleTransitionProviding
    
    var imageScaleTransitionView: UIImageView?
    
    // MARK: - DetailTransitionSourceProviding
    
    var detailTransitionSourceRect: CGRect?
    
    // MARK: - UICollectionViewDataSource
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
       return numberOfItemsInSection(section)
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let maybeCell = collectionView.dequeueReusableCell(withReuseIdentifier: ExploreCardCollectionViewCell.identifier, for: indexPath)
        guard let cell = maybeCell as? ExploreCardCollectionViewCell else {
            return maybeCell
        }
        cell.apply(theme: theme)
        configure(cell: cell, forItemAt: indexPath, layoutOnly: false)
        return cell
    }
    
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader else {
            abort()
        }
        guard let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: CollectionViewHeader.identifier, for: indexPath) as? CollectionViewHeader else {
            abort()
        }
        configureHeader(header, for: indexPath.section)
        return header
    }
    
    // MARK: - UICollectionViewDelegate
    
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let group = group(at: indexPath) else {
            return false
        }
        return group.isSelectable
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        var titleAreaTapped = false
        if let cell = collectionView.cellForItem(at: indexPath) as? ExploreCardCollectionViewCell {
            detailTransitionSourceRect = view.convert(cell.frame, from: collectionView)
            if
                let vc = cell.cardContent as? ExploreCardViewController,
                vc.collectionView.numberOfSections > 0, vc.collectionView.numberOfItems(inSection: 0) > 0,
                let cell = vc.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? ArticleCollectionViewCell
            {
                imageScaleTransitionView = cell.imageView.isHidden ? nil : cell.imageView
            } else {
                imageScaleTransitionView = nil
            }
            titleAreaTapped = cell.titleAreaTapped
        }
        guard let group = group(at: indexPath) else {
            return
        }

        presentedContentGroupKey = group.key
        
        // When a random article title is tapped, show the previewed article, not another random article
        let useRandomArticlePreviewItem = titleAreaTapped && group.moreType == .pageWithRandomButton

        if !useRandomArticlePreviewItem, let vc = group.detailViewControllerWithDataStore(dataStore, theme: theme, imageRecDelegate: self, imageRecLoggingDelegate: self) {
            
            if vc is WKImageRecommendationsViewController {
                ImageRecommendationsFunnel.shared.logExploreCardDidTapAddImage()
            }
            
            push(vc, animated: true)
            return
        }
        
        if let vc = group.detailViewControllerForPreviewItemAtIndex(0, dataStore: dataStore, theme: theme) {
            if vc is WMFImageGalleryViewController {
                present(vc, animated: true)
            } else {
                push(vc, animated: true)
            }
            return
        }
    }
    
    func configureHeader(_ header: CollectionViewHeader, for sectionIndex: Int) {
        guard collectionView(collectionView, numberOfItemsInSection: sectionIndex) > 0 else {
            return
        }
        guard let group = group(at: IndexPath(item: 0, section: sectionIndex)) else {
            return
        }
        header.title = (group.midnightUTCDate as NSDate?)?.wmf_localizedRelativeDateFromMidnightUTCDate()
        header.apply(theme: theme)
    }
    
    func createNewCardVCFor(_ cell: ExploreCardCollectionViewCell) -> ExploreCardViewController {
        let cardVC = ExploreCardViewController()
        cardVC.delegate = self
        cardVC.dataStore = dataStore
        cardVC.view.autoresizingMask = []
        addChild(cardVC)
        cell.cardContent = cardVC
        cardVC.didMove(toParent: self)
        return cardVC
    }

    func configure(cell: ExploreCardCollectionViewCell, forItemAt indexPath: IndexPath, layoutOnly: Bool) {
        let cardVC = cell.cardContent as? ExploreCardViewController ?? createNewCardVCFor(cell)
        guard let group = group(at: indexPath) else {
            return
        }
        cardVC.contentGroup = group
        cell.title = group.headerTitle
        cell.subtitle = group.headerSubTitle
        cell.footerTitle = cardVC.footerText
        cell.isCustomizationButtonHidden = !(group.contentGroupKind.isCustomizable || group.contentGroupKind.isGlobal)
        cell.undoType = group.undoType
        cell.apply(theme: theme)
        cell.delegate = self
        if group.undoType == .contentGroupKind {
            indexPathsForCollapsedCellsThatCanReappear.insert(indexPath)
        }
    }
    
    override func apply(theme: Theme) {
        super.apply(theme: theme)
        guard viewIfLoaded != nil else {
            return
        }

        self.theme = theme
        updateNotificationsCenterButton()
        updateSettingsButton()

        collectionView.backgroundColor = .clear
        view.backgroundColor = theme.colors.paperBackground
        for cell in collectionView.visibleCells {
            guard let themeable = cell as? Themeable else {
                continue
            }
            themeable.apply(theme: theme)
        }
        for header in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let themeable = header as? Themeable else {
                continue
            }
            themeable.apply(theme: theme)
        }
    }
    
    // MARK: - ColumnarCollectionViewLayoutDelegate

    override func collectionView(_ collectionView: UICollectionView, estimatedHeightForItemAt indexPath: IndexPath, forColumnWidth columnWidth: CGFloat) -> ColumnarCollectionViewLayoutHeightEstimate {
        guard let group = group(at: indexPath) else {
            return ColumnarCollectionViewLayoutHeightEstimate(precalculated: true, height: 0)
        }
        let identifier = ExploreCardCollectionViewCell.identifier
        let userInfo = "evc-cell-\(group.inMemoryKey?.userInfoString ?? "")"
        if let cachedHeight = layoutCache.cachedHeightForCellWithIdentifier(identifier, columnWidth: columnWidth, userInfo: userInfo) {
            return ColumnarCollectionViewLayoutHeightEstimate(precalculated: true, height: cachedHeight)
        }
        var estimate = ColumnarCollectionViewLayoutHeightEstimate(precalculated: false, height: 100)
        guard let placeholderCell = layoutManager.placeholder(forCellWithReuseIdentifier: ExploreCardCollectionViewCell.identifier) as? ExploreCardCollectionViewCell else {
            return estimate
        }
        configure(cell: placeholderCell, forItemAt: indexPath, layoutOnly: true)
        estimate.height = placeholderCell.sizeThatFits(CGSize(width: columnWidth, height: UIView.noIntrinsicMetric), apply: false).height
        estimate.precalculated = true
        layoutCache.setHeight(estimate.height, forCellWithIdentifier: identifier, columnWidth: columnWidth, groupKey: group.inMemoryKey, userInfo: userInfo)
        return estimate
    }
    
    override func collectionView(_ collectionView: UICollectionView, estimatedHeightForHeaderInSection section: Int, forColumnWidth columnWidth: CGFloat) -> ColumnarCollectionViewLayoutHeightEstimate {
        guard let group = self.group(at: IndexPath(item: 0, section: section)), let date = group.midnightUTCDate, date < Date() else {
            return ColumnarCollectionViewLayoutHeightEstimate(precalculated: true, height: 0)
        }
        var estimate = ColumnarCollectionViewLayoutHeightEstimate(precalculated: false, height: 100)
        guard let header = layoutManager.placeholder(forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: CollectionViewHeader.identifier) as? CollectionViewHeader else {
            return estimate
        }
        configureHeader(header, for: section)
        estimate.height = header.sizeThatFits(CGSize(width: columnWidth, height: UIView.noIntrinsicMetric), apply: false).height
        estimate.precalculated = true
        return estimate
    }
    
    override func metrics(with size: CGSize, readableWidth: CGFloat, layoutMargins: UIEdgeInsets) -> ColumnarCollectionViewLayoutMetrics {
        return ColumnarCollectionViewLayoutMetrics.exploreViewMetrics(with: size, readableWidth: readableWidth, layoutMargins: layoutMargins)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldShowFooterForSection section: Int) -> Bool {
        return false
    }
    
    // MARK: - ExploreCardViewControllerDelegate
    
    func exploreCardViewController(_ exploreCardViewController: ExploreCardViewController, didSelectItemAtIndexPath indexPath: IndexPath) {
        guard
            let contentGroup = exploreCardViewController.contentGroup,
            let vc = contentGroup.detailViewControllerForPreviewItemAtIndex(indexPath.row, dataStore: dataStore, theme: theme, imageRecDelegate: self, imageRecLoggingDelegate: self) else {
            return
        }
        
        if let cell = exploreCardViewController.collectionView.cellForItem(at: indexPath) {
            detailTransitionSourceRect = view.convert(cell.frame, from: exploreCardViewController.collectionView)
            if let articleCell = cell as? ArticleCollectionViewCell, !articleCell.imageView.isHidden {
                imageScaleTransitionView = articleCell.imageView
            } else {
                imageScaleTransitionView = nil
            }
        }
    
        if let otdvc = vc as? OnThisDayViewController {
            otdvc.initialEvent = (contentGroup.contentPreview as? [Any])?[indexPath.item] as? WMFFeedOnThisDayEvent
        }
        
        if vc is WKImageRecommendationsViewController {
            ImageRecommendationsFunnel.shared.logExploreCardDidTapAddImage()
        }
        
        presentedContentGroupKey = contentGroup.key
        switch contentGroup.detailType {
        case .gallery:
            present(vc, animated: true)
        default:
            push(vc, animated: true)
        }
    }
    
    // MARK: - Prefetching
    
    override func imageURLsForItemAt(_ indexPath: IndexPath) -> Set<URL>? {
        guard let contentGroup = group(at: indexPath) else {
            return nil
        }
        return contentGroup.imageURLsCompatibleWithTraitCollection(traitCollection, dataStore: dataStore)
    }
    
    #if DEBUG
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            return
        }
        dataStore.feedContentController.debugChaos()
    }
    #endif
    
    // MARK: - CollectionViewUpdaterDelegate
    
    var needsReloadVisibleCells = false
    var indexPathsForCollapsedCellsThatCanReappear = Set<IndexPath>()
    
    private func reloadVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ExploreCardCollectionViewCell else {
                continue
            }
            configure(cell: cell, forItemAt: indexPath, layoutOnly: false)
        }
    }
    
    func collectionViewUpdater<T: NSFetchRequestResult>(_ updater: CollectionViewUpdater<T>, didUpdate collectionView: UICollectionView) {
		
        guard needsReloadVisibleCells else {
            return
        }
        
        reloadVisibleCells()
        
        needsReloadVisibleCells = false
        layout.currentSection = nil
    }
    
    func collectionViewUpdater<T: NSFetchRequestResult>(_ updater: CollectionViewUpdater<T>, updateItemAtIndexPath indexPath: IndexPath, in collectionView: UICollectionView) {
        layoutCache.invalidateGroupKey(groupKey(at: indexPath))
        collectionView.collectionViewLayout.invalidateLayout()
        if wantsDeleteInsertOnNextItemUpdate {
            layout.currentSection = indexPath.section
            collectionView.deleteItems(at: [indexPath])
            collectionView.insertItems(at: [indexPath])
        } else {
            needsReloadVisibleCells = true
        }
    }

    // MARK: Event logging

    var eventLoggingCategory: EventCategoryMEP {
        return .feed
    }

    var eventLoggingLabel: EventLabelMEP? {
        return previewed.context?.getAnalyticsLabel()
    }

    // MARK: - For NestedCollectionViewContextMenuDelegate
    private var previewed: (context: WMFContentGroup?, indexPathItem: Int?)

    func contextMenu(with contentGroup: WMFContentGroup? = nil, for articleURL: URL? = nil, at itemIndex: Int) -> UIContextMenuConfiguration? {
        guard let contentGroup = contentGroup, let vc = viewController(for: contentGroup, at: itemIndex) else {
            return nil
        }

        let previewProvider: () -> UIViewController? = {
            return vc
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: previewProvider) { (suggestedActions) -> UIMenu? in
            if let articleVC = vc as? ArticleViewController {
                return UIMenu(title: "", image: nil, identifier: nil, options: [], children: articleVC.contextMenuItems)
            } else {
                return nil
            }
        }
    }

    func viewController(for contentGroup: WMFContentGroup, at itemIndex: Int) -> UIViewController? {
        previewed.context = contentGroup

        if let viewControllerToCommit = contentGroup.detailViewControllerForPreviewItemAtIndex(itemIndex, dataStore: dataStore, theme: theme) {
            if let potd = viewControllerToCommit as? WMFImageGalleryViewController {
                potd.setOverlayViewTopBarHidden(true)
            } else if let avc = viewControllerToCommit as? ArticleViewController {
                avc.articlePreviewingDelegate = self
                avc.wmf_addPeekableChildViewController(for: avc.articleURL, dataStore: dataStore, theme: theme)
            } else if let otdVC = viewControllerToCommit as? OnThisDayViewController {
                otdVC.initialEvent = (contentGroup.contentPreview as? [Any])?[itemIndex] as? WMFFeedOnThisDayEvent
                otdVC.navigationMode = .bar
            } else if let newsVC = viewControllerToCommit as? NewsViewController {
                newsVC.navigationMode = .bar
            }

            previewed.indexPathItem = itemIndex


            return viewControllerToCommit
        } else if contentGroup.contentGroupKind != .random {
            return contentGroup.detailViewControllerWithDataStore(dataStore, theme: theme)
        } else {
            return nil
        }
    }

    func willCommitPreview(with animator: UIContextMenuInteractionCommitAnimating) {
        guard let viewControllerToCommit = animator.previewViewController else {
            assertionFailure("Should be able to find previewed VC")
            return
        }
        animator.addCompletion { [weak self] in
            guard let self = self else {
                return
            }
            if let potd = viewControllerToCommit as? WMFImageGalleryViewController {
                potd.setOverlayViewTopBarHidden(false)
                self.present(potd, animated: false)
            } else if let avc = viewControllerToCommit as? ArticleViewController {
                avc.wmf_removePeekableChildViewControllers()
                self.push(avc, animated: false)
            } else if let otdVC = viewControllerToCommit as? OnThisDayViewController {
                otdVC.navigationMode = .detail
                self.push(viewControllerToCommit, animated: true)
            } else if let newsVC = viewControllerToCommit as? NewsViewController {
                newsVC.navigationMode = .detail
                self.push(viewControllerToCommit, animated: true)
            } else {
                self.push(viewControllerToCommit, animated: true)
            }
        }
    }

    override func readMoreArticlePreviewActionSelected(with articleController: ArticleViewController) {
        articleController.wmf_removePeekableChildViewControllers()
        push(articleController, animated: true)
    }

    override func saveArticlePreviewActionSelected(with articleController: ArticleViewController, didSave: Bool, articleURL: URL) {
        if let date = previewed.context?.midnightUTCDate {
            if didSave {
                ReadingListsFunnel.shared.logSaveInFeed(label: previewed.context?.getAnalyticsLabel(), measureAge: date, articleURL: articleURL, index: previewed.indexPathItem)
            } else {
                ReadingListsFunnel.shared.logUnsaveInFeed(label: previewed.context?.getAnalyticsLabel(), measureAge: date, articleURL: articleURL, index: previewed.indexPathItem)
            }
        }
    }

    var addArticlesToReadingListVCDidDisappear: (() -> Void)? = nil
    
    private func presentImageRecommendationsFeatureAnnouncementIfNeeded() {
        
        guard let fetchedResultsController,
            let groups = fetchedResultsController.fetchedObjects else {
            return
        }
        
        let suggestedEditsCardObjects = groups.filter { $0.contentGroupKindInteger == WMFContentGroupKind.suggestedEdits.rawValue}
        guard let suggestedEditsCardObject = suggestedEditsCardObjects.first else {
            return
        }
        
        guard presentedViewController == nil else {
            return
        }
        
        guard self.isViewLoaded && self.view.window != nil else {
            return
        }
        
        let imageRecommendationsDataController = WKImageRecommendationsDataController()
        guard !imageRecommendationsDataController.hasPresentedFeatureAnnouncementModal else {
            return
        }
        
        guard let indexPath = fetchedResultsController.indexPath(forObject: suggestedEditsCardObject) else {
            return
        }
        
        guard let cell = collectionView.cellForItem(at: indexPath),
        let sourceRect = cell.superview?.convert(cell.frame, to: view) else {
            return
        }
        
        let viewModel = WKFeatureAnnouncementViewModel(title: WMFLocalizedString("image-rec-feature-announce-title", value: "Try 'Add an image'", comment: "Title of image recommendations feature announcement modal. Displayed the first time a user lands on the Explore feed after the feature has been added (if eligible)."), body: WMFLocalizedString("image-rec-feature-announce-body", value: "Decide if an image gets added to a Wikipedia article. You can find the ‘Add an image’ card in your ‘Explore feed’.", comment: "Body of image recommendations feature announcement modal. Displayed the first time a user lands on the Explore feed after the feature has been added (if eligible)."), primaryButtonTitle: CommonStrings.tryNowTitle, image:  WKIcon.addPhoto, primaryButtonAction: { [weak self] in
            
            guard let self,
                  let imageRecommendationViewController = WKImageRecommendationsViewController.imageRecommendationsViewController(dataStore: self.dataStore, imageRecDelegate: self, imageRecLoggingDelegate: self) else {
                return
            }
            
            navigationController?.pushViewController(imageRecommendationViewController, animated: true)
            
            ImageRecommendationsFunnel.shared.logExploreDidTapFeatureAnnouncementPrimaryButton()
            
        })
        
        announceFeature(viewModel: viewModel, sourceView:view, sourceRect:sourceRect)

       imageRecommendationsDataController.hasPresentedFeatureAnnouncementModal = true
    }
}

// MARK: - Analytics
extension ExploreViewController {
    private func logArticleSavedStateChange(_ wasArticleSaved: Bool, saveButton: SaveButton?, article: WMFArticle, userInfo: Any?) {
        guard let articleURL = article.url else {
            assert(false, "Article missing url: \(article)")
            return
        }
        guard
            let userInfo = userInfo as? ExploreSaveButtonUserInfo,
            let midnightUTCDate = userInfo.midnightUTCDate,
            let kind = userInfo.kind
        else {
            assert(false, "Article missing user info: \(article)")
            return
        }
        let index = userInfo.indexPath.item
        if wasArticleSaved {
            ReadingListsFunnel.shared.logSaveInFeed(saveButton: saveButton, articleURL: articleURL, kind: kind, index: index, date: midnightUTCDate)
        } else {
            ReadingListsFunnel.shared.logUnsaveInFeed(saveButton: saveButton, articleURL: articleURL, kind: kind, index: index, date: midnightUTCDate)
        }
    }
}

extension ExploreViewController: SaveButtonsControllerDelegate {
    func didSaveArticle(_ saveButton: SaveButton?, didSave: Bool, article: WMFArticle, userInfo: Any?) {
        let logSavedEvent = {
            self.logArticleSavedStateChange(didSave, saveButton: saveButton, article: article, userInfo: userInfo)
        }
        if isPresentingAddArticlesToReadingListVC() {
            addArticlesToReadingListVCDidDisappear = logSavedEvent
        } else {
            logSavedEvent()
        }
    }
    
    func willUnsaveArticle(_ article: WMFArticle, userInfo: Any?) {
        if article.userCreatedReadingListsCount > 0 {
            let alertController = ReadingListsAlertController()
            alertController.showAlert(presenter: self, article: article)
        } else {
            saveButtonsController.updateSavedState()
        }
    }
    
    func showAddArticlesToReadingListViewController(for article: WMFArticle) {
        let addArticlesToReadingListViewController = AddArticlesToReadingListViewController(with: dataStore, articles: [article], moveFromReadingList: nil, theme: theme)
        addArticlesToReadingListViewController.delegate = self
        let navigationController = WMFThemeableNavigationController(rootViewController: addArticlesToReadingListViewController, theme: self.theme)
        navigationController.isNavigationBarHidden = true
        present(navigationController, animated: true)
    }

    private func isPresentingAddArticlesToReadingListVC() -> Bool {
        guard let navigationController = presentedViewController as? UINavigationController else {
            return false
        }
        return navigationController.viewControllers.contains { $0 is AddArticlesToReadingListViewController }
    }
}

extension ExploreViewController: AddArticlesToReadingListDelegate {
    func addArticlesToReadingListWillClose(_ addArticlesToReadingList: AddArticlesToReadingListViewController) {
    }

    func addArticlesToReadingListDidDisappear(_ addArticlesToReadingList: AddArticlesToReadingListViewController) {
        addArticlesToReadingListVCDidDisappear?()
        addArticlesToReadingListVCDidDisappear = nil
    }

    func addArticlesToReadingList(_ addArticlesToReadingList: AddArticlesToReadingListViewController, didAddArticles articles: [WMFArticle], to readingList: ReadingList) {
    }
}

extension ExploreViewController: ReadingListsAlertControllerDelegate {
    func readingListsAlertController(_ readingListsAlertController: ReadingListsAlertController, didSelectUnsaveForArticle: WMFArticle) {
        saveButtonsController.updateSavedState()
    }
}

extension ExploreViewController: ExploreCardCollectionViewCellDelegate {
    func exploreCardCollectionViewCellWantsCustomization(_ cell: ExploreCardCollectionViewCell) {
        guard let vc = cell.cardContent as? ExploreCardViewController,
            let group = vc.contentGroup else {
            return
        }
        guard let sheet = menuActionSheetForGroup(group) else {
            return
        }
        sheet.popoverPresentationController?.sourceView = cell.customizationButton
        sheet.popoverPresentationController?.sourceRect = cell.customizationButton.bounds
        present(sheet, animated: true)
    }

    private func save() {
        do {
            try self.dataStore.save()
        } catch let error {
            DDLogError("Error saving after cell customization update: \(error)")
        }
    }

    @objc func exploreFeedPreferencesDidSave(_ note: Notification) {
        DispatchQueue.main.async {
            for indexPath in self.indexPathsForCollapsedCellsThatCanReappear {
                guard self.fetchedResultsController?.isValidIndexPath(indexPath) ?? false else {
                    continue
                }
                self.layoutCache.invalidateGroupKey(self.groupKey(at: indexPath))
                self.collectionView.collectionViewLayout.invalidateLayout()
            }
            self.indexPathsForCollapsedCellsThatCanReappear = []
        }
    }
    
    @objc func articleDidChange(_ note: Notification) {
        guard
            let article = note.object as? WMFArticle,
            let articleKey = article.inMemoryKey
        else {
            return
        }

        var needsReload = false
        if article.hasChangedValuesForCurrentEventThatAffectPreviews, layoutCache.invalidateArticleKey(articleKey) {
            needsReload = true
            collectionView.collectionViewLayout.invalidateLayout()
        } else if !article.hasChangedValuesForCurrentEventThatAffectSavedState {
            return
        }

        let visibleIndexPathsWithChanges = collectionView.indexPathsForVisibleItems.filter { (indexPath) -> Bool in
            guard let contentGroup = group(at: indexPath) else {
                return false
            }
            return contentGroup.previewArticleKeys.contains(articleKey)
        }
        
        guard !visibleIndexPathsWithChanges.isEmpty else {
            return
        }
        
        for indexPath in visibleIndexPathsWithChanges {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ExploreCardCollectionViewCell else {
                continue
            }
            if needsReload {
                configure(cell: cell, forItemAt: indexPath, layoutOnly: false)
            } else if let cardVC = cell.cardContent as? ExploreCardViewController {
                cardVC.savedStateDidChangeForArticleWithKey(articleKey)
            }
        }
    }
    
    @objc func articleDeleted(_ note: Notification) {
        guard let articleKey = note.userInfo?[WMFArticleDeletedNotificationUserInfoArticleKeyKey] as? WMFInMemoryURLKey else {
            return
        }
        layoutCache.invalidateArticleKey(articleKey)
    }
    
    @objc func viewContextDidReset(_ note: Notification) {
        collectionView.reloadData()
    }

    private func menuActionSheetForGroup(_ group: WMFContentGroup) -> UIAlertController? {
        guard group.contentGroupKind.isCustomizable || group.contentGroupKind.isGlobal else {
            return nil
        }
        let hideThisCardHidesAll = group.contentGroupKind.isGlobal && group.contentGroupKind.isNonDateBased
        
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let customizeExploreFeed = UIAlertAction(title: CommonStrings.customizeExploreFeedTitle, style: .default) { (_) in
            let exploreFeedSettingsViewController = ExploreFeedSettingsViewController()
            exploreFeedSettingsViewController.showCloseButton = true
            exploreFeedSettingsViewController.dataStore = self.dataStore
            exploreFeedSettingsViewController.apply(theme: self.theme)
            let themeableNavigationController = WMFThemeableNavigationController(rootViewController: exploreFeedSettingsViewController, theme: self.theme)
            themeableNavigationController.modalPresentationStyle = .formSheet
            self.present(themeableNavigationController, animated: true)
        }
        
        let hideThisCardHandler: ((UIAlertAction) -> Void) = { (_) in
            group.undoType = .contentGroup
            self.wantsDeleteInsertOnNextItemUpdate = true
            self.save()
        }
        
        let hideAllHandler: ((UIAlertAction) -> Void) = { (_) in
            let feedContentController = self.dataStore.feedContentController
            // If there's only one group left it means that we're about to show an alert about turning off the Explore tab. In those cases, we don't want to provide the option to undo.
            if feedContentController.countOfVisibleContentGroupKinds > 1 {
                group.undoType = .contentGroupKind
                self.wantsDeleteInsertOnNextItemUpdate = true
            }
            feedContentController.toggleContentGroup(of: group.contentGroupKind, isOn: false, waitForCallbackFromCoordinator: true, apply: true, updateFeed: false)
        }
        
        let hideThisCard = UIAlertAction(title: WMFLocalizedString("explore-feed-preferences-hide-card-action-title", value: "Hide this card", comment: "Title for action that allows users to hide a feed card"), style: .default, handler: hideThisCardHidesAll ? hideAllHandler : hideThisCardHandler)
        
        guard let title = group.headerTitle else {
            assertionFailure("Expected header title for group \(group.contentGroupKind)")
            return nil
        }
        
        let hideAllCards = UIAlertAction(title: String.localizedStringWithFormat(WMFLocalizedString("explore-feed-preferences-hide-feed-cards-action-title", value: "Hide all “%@” cards", comment: "Title for action that allows users to hide all feed cards of given type - %@ is replaced with feed card type"), title), style: .default, handler: hideAllHandler)
        
        let cancel = UIAlertAction(title: CommonStrings.cancelActionTitle, style: .cancel)
        sheet.addAction(hideThisCard)
        if group.contentGroupKind != WMFContentGroupKind.notification && (!hideThisCardHidesAll) {
            sheet.addAction(hideAllCards)
        }
        sheet.addAction(customizeExploreFeed)
        sheet.addAction(cancel)

        return sheet
    }

    func exploreCardCollectionViewCellWantsToUndoCustomization(_ cell: ExploreCardCollectionViewCell) {
        guard let vc = cell.cardContent as? ExploreCardViewController,
            let group = vc.contentGroup else {
                return
        }
        if group.undoType == .contentGroupKind {
            dataStore.feedContentController.toggleContentGroup(of: group.contentGroupKind, isOn: true, waitForCallbackFromCoordinator: false, apply: true, updateFeed: false)
        }
        group.undoType = .none
        wantsDeleteInsertOnNextItemUpdate = true
        if let indexPath = fetchedResultsController?.indexPath(forObject: group) {
            indexPathsForCollapsedCellsThatCanReappear.remove(indexPath)
        }
        save()
    }
    
}

// MARK: - Notifications Center
extension ExploreViewController {

    @objc func userDidTapNotificationsCenter() {
        notificationsCenterPresentationDelegate?.userDidTapNotificationsCenter(from: self)
    }

    @objc func pushNotificationBannerDidDisplayInForeground(_ notification: Notification) {
        dataStore.remoteNotificationsController.loadNotifications(force: true)
    }

    @objc func applicationDidBecomeActive() {
        if !UIAccessibility.isVoiceOverRunning {
            presentImageRecommendationsFeatureAnnouncementIfNeeded()
        }
    }
}

extension ExploreViewController: WKImageRecommendationsDelegate {

    func imageRecommendationsUserDidTapImage(project: WKProject, data: WKImageRecommendationsViewModel.WKImageRecommendationData, presentingVC: UIViewController) {

        guard let siteURL = project.siteURL,
              let articleURL = siteURL.wmf_URL(withTitle: data.pageTitle) else {
            return
        }

        let item = MediaListItem(title: "File:\(data.filename)", sectionID: 0, type: .image, showInGallery: true, isLeadImage: false, sources: nil)
        let mediaList = MediaList(items: [item])

        let gallery = MediaListGalleryViewController(articleURL: articleURL, mediaList: mediaList, dataStore: dataStore, initialItem: item, theme: theme)
        presentingVC.present(gallery, animated: true)
    }

    func imageRecommendationsUserDidTapViewArticle(project: WKData.WKProject, title: String) {
        
        guard let siteURL = project.siteURL,
              let articleURL = siteURL.wmf_URL(withTitle: title),
              let articleViewController = ArticleViewController(articleURL: articleURL, dataStore: dataStore, theme: theme) else {
            return
        }
        
        navigationController?.pushViewController(articleViewController, animated: true)
    }
    
    func imageRecommendationsUserDidTapImageLink(commonsURL: URL) {
        navigate(to: commonsURL, useSafari: false)
        ImageRecommendationsFunnel.shared.logCommonsWebViewDidAppear()
    }

    func imageRecommendationsUserDidTapInsertImage(viewModel: WKImageRecommendationsViewModel, title: String, with imageData: WKImageRecommendationsViewModel.WKImageRecommendationData) {

        guard let image = imageData.uiImage else {
            return
        }
        
        if let imageURL = URL(string: imageData.descriptionURL),
           let thumbURL = URL(string: imageData.thumbUrl) {
            
            let fileName = imageData.filename.normalizedPageTitle ?? imageData.filename
            let imageDescription = imageData.description?.removingHTML
            let searchResult = InsertMediaSearchResult(fileTitle: "File:\(imageData.filename)", displayTitle: fileName, thumbnailURL: thumbURL, imageDescription: imageDescription,  filePageURL: imageURL)
            
            let insertMediaViewController = InsertMediaSettingsViewController(image: image, searchResult: searchResult, fromImageRecommendations: true, delegate: self, imageRecLoggingDelegate: self, theme: theme)
            self.imageRecommendationsViewModel = viewModel
            navigationController?.pushViewController(insertMediaViewController, animated: true)
        }
    }
    
    func imageRecommendationsDidTriggerError(_ error: any Error) {
        WMFAlertManager.sharedInstance.showErrorAlert(error, sticky: false, dismissPreviousAlerts: true)
    }
}

extension ExploreViewController: InsertMediaSettingsViewControllerDelegate {
    func insertMediaSettingsViewControllerDidTapProgress(imageWikitext: String, caption: String?, altText: String?) {
        
        guard let viewModel = imageRecommendationsViewModel,
        let currentRecommendation = viewModel.currentRecommendation,
                    let siteURL = viewModel.project.siteURL,
              let articleURL = siteURL.wmf_URL(withTitle: currentRecommendation.title),
        let articleWikitext = currentRecommendation.imageData.wikitext else {
            return
        }
        
        currentRecommendation.caption = caption
        currentRecommendation.altText = altText
        
        do {
            let wikitextWithImage = try WKWikitextUtils.insertImageWikitextIntoArticleWikitextAfterTemplates(imageWikitext: imageWikitext, into: articleWikitext)
            
            let editPreviewViewController = EditPreviewViewController(pageURL: articleURL)
            editPreviewViewController.theme = theme
            editPreviewViewController.sectionID = 0
            editPreviewViewController.languageCode = articleURL.wmf_languageCode
            editPreviewViewController.wikitext = wikitextWithImage
            editPreviewViewController.delegate = self
            editPreviewViewController.loggingDelegate = self

            navigationController?.pushViewController(editPreviewViewController, animated: true)
        } catch {
            showGenericError()
        }
    }
}

extension ExploreViewController: EditPreviewViewControllerDelegate {
    func editPreviewViewControllerDidTapNext(pageURL: URL, sectionID: Int?, editPreviewViewController: EditPreviewViewController) {
        guard let saveVC = EditSaveViewController.wmf_initialViewControllerFromClassStoryboard() else {
            return
        }

        saveVC.dataStore = dataStore
        saveVC.pageURL = pageURL
        saveVC.sectionID = sectionID
        saveVC.languageCode = pageURL.wmf_languageCode
        saveVC.wikitext = editPreviewViewController.wikitext
        saveVC.cannedSummaryTypes = [.addedImage, .addedImageAndCaption]
        saveVC.needsSuppressPosting = FeatureFlags.needsImageRecommendationsSuppressPosting

        saveVC.delegate = self
        saveVC.imageRecLoggingDelegate = self
        saveVC.theme = self.theme
        
        navigationController?.pushViewController(saveVC, animated: true)
    }

    func imageRecommendationsUserDidTapLearnMore(url: URL?) {
        navigate(to: url, useSafari: false)
    }

    func imageRecommendationsUserDidTapReportIssue() {
        let emailAddress = "ios-support@wikimedia.org"
        let emailSubject = WMFLocalizedString("image-recommendations-email-title", value: "Issue Report - Add an Image Feature", comment: "Title text for Image recommendations pre-filled issue report email")
        let emailBodyLine1 = WMFLocalizedString("image-recommendations-email-first-line", value: "I’ve encountered a problem with the Add an Image Suggested Edits Feature:", comment: "Text for Image recommendations pre-filled issue report email")
        let emailBodyLine2 = WMFLocalizedString("image-recommendations-email-second-line", value: "- [Describe specific problem]", comment: "Text for Image recommendations pre-filled issue report email. This text is intended to be replaced by the user with a description of the problem they are encountering")
        let emailBodyLine3 = WMFLocalizedString("image-recommendations-email-third-line", value: "The behavior I would like to see is:", comment: "Text for Image recommendations pre-filled issue report email")
        let emailBodyLine4 = WMFLocalizedString("image-recommendations-email-fourth-line", value: "- [Describe proposed solution]", comment: "Text for Image recommendations pre-filled issue report email. This text is intended to be replaced by the user with a description of a user suggested solution")
        let emailBodyLine5 = WMFLocalizedString("image-recommendations-email-fifth-line", value: "[Screenshots or Links]", comment: "Text for Image recommendations pre-filled issue report email. This text is intended to be replaced by the user with a screenshot or link.")
        let emailBody = "\(emailBodyLine1)\n\n\(emailBodyLine2)\n\n\(emailBodyLine3)\n\n\(emailBodyLine4)\n\n\(emailBodyLine5)"
        let mailto = "mailto:\(emailAddress)?subject=\(emailSubject)&body=\(emailBody)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        guard let encodedMailto = mailto, let mailtoURL = URL(string: encodedMailto), UIApplication.shared.canOpenURL(mailtoURL) else {
            WMFAlertManager.sharedInstance.showErrorAlertWithMessage(CommonStrings.noEmailClient, sticky: false, dismissPreviousAlerts: false)
            return
        }
        UIApplication.shared.open(mailtoURL)
    }

}

extension ExploreViewController: EditSaveViewControllerDelegate {
    
    func editSaveViewControllerDidSave(_ editSaveViewController: EditSaveViewController, result: Result<SectionEditorChanges, any Error>) {
        
        switch result {
        case .success(let changes):
            sendFeedbackAndPopToImageRecommendations(revID: changes.newRevisionID)
        case .failure(let error):
            showError(error)
        }
        
    }
    
    private func sendFeedbackAndPopToImageRecommendations(revID: UInt64) {

        guard let viewControllers = navigationController?.viewControllers,
        let imageRecommendationsViewModel,
        let currentRecommendation = imageRecommendationsViewModel.currentRecommendation else {
            return
        }
        
        for viewController in viewControllers {
            if viewController is WKImageRecommendationsViewController {
                navigationController?.popToViewController(viewController, animated: true)
                
                // Send Feedback
                imageRecommendationsViewModel.sendFeedback(editRevId: revID, accepted: true, caption: currentRecommendation.caption) { result in
                }
                
                // Go to next recommendation and display success alert
                imageRecommendationsViewModel.next {
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let title = CommonStrings.editPublishedToastTitle
                        let image = UIImage(systemName: "checkmark.circle.fill")
                        
                        if UIAccessibility.isVoiceOverRunning {
                            UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: title)
                        } else {
                            WMFAlertManager.sharedInstance.showBottomAlertWithMessage(title, subtitle: nil, image: image, type: .custom, customTypeName: "edit-published", dismissPreviousAlerts: true)
                        }
                    }
                    
                }
                
                break
            }
        }
        
        self.imageRecommendationsViewModel = nil
    }
    
    func editSaveViewControllerWillCancel(_ saveData: EditSaveViewController.SaveData) {
        // no-op
    }
    
    func editSaveViewControllerDidTapShowWebPreview() {
        assertionFailure("This should not be called in the Image Recommendations context")
    }
}

extension ExploreViewController: WKFeatureAnnouncing {
    
}

extension ExploreViewController: WKImageRecommendationsLoggingDelegate {
    
    func logOnboardingDidTapPrimaryButton() {
        ImageRecommendationsFunnel.shared.logOnboardingDidTapContinue()
    }
    
    func logOnboardingDidTapSecondaryButton() {
        ImageRecommendationsFunnel.shared.logOnboardingDidTapLearnMore()
    }
    
    func logTooltipsDidTapFirstNext() {
        ImageRecommendationsFunnel.shared.logTooltipDidTapFirstNext()
    }
    
    func logTooltipsDidTapSecondNext() {
        ImageRecommendationsFunnel.shared.logTooltipDidTapSecondNext()
    }
    
    func logTooltipsDidTapThirdOK() {
        ImageRecommendationsFunnel.shared.logTooltipDidTapThirdOk()
    }
    
    func logBottomSheetDidAppear() {
        ImageRecommendationsFunnel.shared.logBottomSheetDidAppear()
    }
    
    func logBottomSheetDidTapYes() {
        
        if let viewModel = imageRecommendationsViewModel,
              let currentRecommendation = viewModel.currentRecommendation,
           let siteURL = viewModel.project.siteURL,
           let pageURL = siteURL.wmf_URL(withTitle: currentRecommendation.title) {
            currentRecommendation.suggestionAcceptDate = Date()
            EditAttemptFunnel.shared.logInit(pageURL: pageURL)
        }
        
        ImageRecommendationsFunnel.shared.logBottomSheetDidTapYes()
    }
    
    func logBottomSheetDidTapNo() {
        ImageRecommendationsFunnel.shared.logBottomSheetDidTapNo()
    }
    
    func logBottomSheetDidTapNotSure() {
        ImageRecommendationsFunnel.shared.logBottomSheetDidTapNotSure()
    }
    
    func logOverflowDidTapLearnMore() {
        ImageRecommendationsFunnel.shared.logOverflowDidTapLearnMore()
    }
    
    func logOverflowDidTapTutorial() {
        ImageRecommendationsFunnel.shared.logOverflowDidTapTutorial()
    }
    
    func logOverflowDidTapProblem() {
        ImageRecommendationsFunnel.shared.logOverflowDidTapProblem()
    }
    
    func logBottomSheetDidTapFileName() {
        ImageRecommendationsFunnel.shared.logBottomSheetDidTapFileName()
    }
    
    func logRejectSurveyDidAppear() {
        ImageRecommendationsFunnel.shared.logRejectSurveyDidAppear()
    }
    
    func logRejectSurveyDidTapCancel() {
        ImageRecommendationsFunnel.shared.logRejectSurveyDidTapCancel()
    }
    
    func logRejectSurveyDidTapSubmit(rejectionReasons: [String], otherReason: String?, fileName: String, recommendationSource: String) {
        
        ImageRecommendationsFunnel.shared.logRejectSurveyDidTapSubmit(rejectionReasons: rejectionReasons, otherReason: otherReason, fileName: fileName, recommendationSource: recommendationSource)
    }
    
    func logEmptyStateDidAppear() {
        ImageRecommendationsFunnel.shared.logEmptyStateDidAppear()
    }
    
    func logEmptyStateDidTapBack() {
        ImageRecommendationsFunnel.shared.logEmptyStateDidTapBack()
    }
}

extension ExploreViewController: InsertMediaSettingsViewControllerLoggingDelegate {
    func logInsertMediaSettingsViewControllerDidAppear() {
        ImageRecommendationsFunnel.shared.logAddImageDetailsDidAppear()
    }
    
    func logInsertMediaSettingsViewControllerDidTapFileName() {
        ImageRecommendationsFunnel.shared.logAddImageDetailsDidTapFileName()
    }
    
    func logInsertMediaSettingsViewControllerDidTapCaptionLearnMore() {
        ImageRecommendationsFunnel.shared.logAddImageDetailsDidTapCaptionLearnMore()
    }
    
    func logInsertMediaSettingsViewControllerDidTapAltTextLearnMore() {
        ImageRecommendationsFunnel.shared.logAddImageDetailsDidTapAltTextLearnMore()
    }
    
    func logInsertMediaSettingsViewControllerDidTapAdvancedSettings() {
        ImageRecommendationsFunnel.shared.logAddImageDetailsDidTapAdvancedSettings()
    }
}

extension ExploreViewController: EditPreviewViewControllerLoggingDelegate {
    func logEditPreviewDidAppear() {
        ImageRecommendationsFunnel.shared.logPreviewDidAppear()
    }
    
    func logEditPreviewDidTapBack() {
        ImageRecommendationsFunnel.shared.logPreviewDidTapBack()
    }
    
    func logEditPreviewDidTapNext() {
        
        if let viewModel = imageRecommendationsViewModel,
              let currentRecommendation = viewModel.currentRecommendation,
           let siteURL = viewModel.project.siteURL,
           let pageURL = siteURL.wmf_URL(withTitle: currentRecommendation.title) {
            EditAttemptFunnel.shared.logSaveIntent(pageURL: pageURL)
        }
        
        ImageRecommendationsFunnel.shared.logPreviewDidTapNext()
    }
}

extension ExploreViewController: EditSaveViewControllerImageRecLoggingDelegate {
    
    func logEditSaveViewControllerDidAppear() {
        ImageRecommendationsFunnel.shared.logSaveChangesDidAppear()
    }
    
    func logEditSaveViewControllerDidTapBack() {
        ImageRecommendationsFunnel.shared.logSaveChangesDidTapBack()
    }
    
    func logEditSaveViewControllerDidTapMinorEditsLearnMore() {
        ImageRecommendationsFunnel.shared.logSaveChangesDidTapMinorEditsLearnMore()
    }
    
    func logEditSaveViewControllerDidTapWatchlistLearnMore() {
        ImageRecommendationsFunnel.shared.logSaveChangesDidTapWatchlistLearnMore()
    }
    
    func logEditSaveViewControllerDidToggleWatchlist(isOn: Bool) {
        ImageRecommendationsFunnel.shared.logSaveChangesDidToggleWatchlist(isOn: isOn)
    }
    
    func logEditSaveViewControllerDidTapPublish(minorEditEnabled: Bool, watchlistEnabled: Bool) {
        ImageRecommendationsFunnel.shared.logSaveChangesDidTapPublish(minorEditEnabled: minorEditEnabled, watchlistEnabled: watchlistEnabled)
    }
    
    func logEditSaveViewControllerPublishSuccess(revisionID: Int, summaryAdded: Bool) {
        
        guard let viewModel = imageRecommendationsViewModel,
              let currentRecommendation = viewModel.currentRecommendation else {
            return
        }
        
        var timeSpent: Int? = nil
        if let suggestionAcceptDate = currentRecommendation.suggestionAcceptDate {
            timeSpent = Int(Date().timeIntervalSince(suggestionAcceptDate))
        }
        
        ImageRecommendationsFunnel.shared.logSaveChangesPublishSuccess(timeSpent: timeSpent, revisionID: revisionID, captionAdded: currentRecommendation.caption != nil, altTextAdded: currentRecommendation.altText != nil, summaryAdded: summaryAdded)
    }
    
    func logEditSaveViewControllerLogPublishFailed(abortSource: String?) {
        ImageRecommendationsFunnel.shared.logSaveChangesPublishFail(abortSource: abortSource)
    }
    
}

extension ExploreViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController.searchBar.text else { return }
        
        guard let searchViewController = navigationItem.searchController?.searchResultsController as? SearchViewController else {
            return
        }
        
        if text.isEmpty {
            searchViewController.searchTerm = nil
            searchViewController.updateRecentlySearchedVisibility(searchText: nil)
        } else {
            searchViewController.searchTerm = text
            searchViewController.updateRecentlySearchedVisibility(searchText: text)
            searchViewController.search()
        }
        
        navigationController?.hidesBarsOnSwipe = !searchController.searchBar.isFirstResponder
    }
}

extension ExploreViewController: SearchTermSelectDelegate {
    var searchBarText: String? {
        navigationItem.searchController?.searchBar.text
    }
    
    func searchViewController(_ searchViewController: SearchViewController, didSelectSearchTerm searchTerm: String, at indexPath: IndexPath) {
        navigationItem.searchController?.searchBar.text = searchTerm
    }
}
