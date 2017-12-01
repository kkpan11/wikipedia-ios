import UIKit
import WMF

class SavedCollectionViewCell: ArticleRightAlignedImageCollectionViewCell {
    
    override func sizeThatFits(_ size: CGSize, apply: Bool) -> CGSize {
        let superSize = super.sizeThatFits(size, apply: apply)
        let isRTL = articleSemanticContentAttribute == .forceRightToLeft
        let minHeight = imageViewDimension + layoutMargins.top + layoutMargins.bottom
        var widthMinusMargins = size.width - layoutMargins.left - layoutMargins.right
        
        if !isImageViewHidden {
            widthMinusMargins = widthMinusMargins - layoutMargins.right - imageViewDimension
        }
        
        var x = layoutMargins.left
        if isRTL {
            x = size.width - x - widthMinusMargins
        }
        
        let origin = CGPoint(x: x, y: layoutMargins.top)
        let height = max(origin.y, minHeight)
        
        if (apply && !isImageViewHidden) {
            let imageViewY = floor(0.5*height - 0.5*imageViewDimension)
            var x = layoutMargins.right
            if !isRTL {
                x = size.width - x - imageViewDimension
            }
            imageView.frame = CGRect(x: x, y: imageViewY, width: imageViewDimension, height: imageViewDimension)
        }
        
        let separatorWidth: CGFloat = isImageViewHidden ? size.width : size.width - (imageViewDimension * 1.8)
        if (apply && !bottomSeparator.isHidden) {
            bottomSeparator.frame = CGRect(x: 0, y: height - singlePixelDimension, width: separatorWidth, height: singlePixelDimension)
        }
        
        if (apply && !topSeparator.isHidden) {
            topSeparator.frame = CGRect(x: 0, y: 0, width: separatorWidth, height: singlePixelDimension)
        }
        
        return superSize
    }
    
}

class SavedArticleCollectionViewCell: SavedCollectionViewCell {
    
}

class ReadingListTag: SizeThatFitsView {
    fileprivate let label: UILabel = UILabel()
    let padding = UIEdgeInsetsMake(3, 3, 3, 3)
    
    override func setup() {
        super.setup()
        layer.borderWidth = 1
        label.isOpaque = true
        addSubview(label)
    }
    
    var readingListName: String = "" {
        didSet {
            label.text = String.localizedStringWithFormat("%d", readingListName)
            setNeedsLayout()
        }
    }
    
    var labelBackgroundColor: UIColor? {
        didSet {
            label.backgroundColor = labelBackgroundColor
        }
    }
    
    override func tintColorDidChange() {
        label.textColor = tintColor
        layer.borderColor = tintColor.cgColor
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        label.font = UIFont.wmf_preferredFontForFontFamily(.system, withTextStyle: .footnote, compatibleWithTraitCollection: traitCollection)
    }
    
    override func sizeThatFits(_ size: CGSize, apply: Bool) -> CGSize {
        let insetSize = UIEdgeInsetsInsetRect(CGRect(origin: .zero, size: size), padding)
        let labelSize = label.sizeThatFits(insetSize.size)
        if (apply) {
            layer.cornerRadius = 3
            label.frame = CGRect(origin: CGPoint(x: 0.5*size.width - 0.5*labelSize.width, y: 0.5*size.height - 0.5*labelSize.height), size: labelSize)
        }
        let width = labelSize.width + padding.left + padding.right
        let height = labelSize.height + padding.top + padding.bottom
        let dimension = max(width, height)
        return CGSize(width: dimension, height: dimension)
    }
}

@objc(WMFSavedArticlesCollectionViewController)
class SavedArticlesCollectionViewController: ArticleFetchedResultsViewController {
    
    fileprivate let reuseIdentifier = "SavedArticleCollectionViewCell"

    override func setupFetchedResultsController(with dataStore: MWKDataStore) {
        let articleRequest = WMFArticle.fetchRequest()
        articleRequest.predicate = NSPredicate(format: "savedDate != NULL")
        articleRequest.sortDescriptors = [NSSortDescriptor(key: "savedDate", ascending: false)]
        fetchedResultsController = NSFetchedResultsController(fetchRequest: articleRequest, managedObjectContext: dataStore.viewContext, sectionNameKeyPath: nil, cacheName: nil)
    }
    
    override func canSave(at indexPath: IndexPath) -> Bool {
        return false
    }
    
    override func canUnsave(at indexPath: IndexPath) -> Bool {
        return false
    }
    
    override func delete(at indexPath: IndexPath) {
        guard let articleURL = self.articleURL(at: indexPath) else {
            return
        }
        dataStore.savedPageList.removeEntry(with: articleURL)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        register(SavedArticleCollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier, addPlaceholder: true)
        deleteAllButtonText = WMFLocalizedString("saved-clear-all", value: "Clear", comment: "Text of the button shown at the top of saved pages which deletes all the saved pages\n{{Identical|Clear}}")
        deleteAllConfirmationText = WMFLocalizedString("saved-pages-clear-confirmation-heading", value: "Are you sure you want to delete all your saved pages?", comment: "Heading text of delete all confirmation dialog")
        deleteAllCancelText = WMFLocalizedString("saved-pages-clear-cancel", value: "Cancel", comment: "Button text for cancelling delete all action\n{{Identical|Cancel}}")
        deleteAllText = WMFLocalizedString("saved-pages-clear-delete-all", value: "Yes, delete all", comment: "Button text for confirming delete all action\n{{Identical|Delete all}}")
        isDeleteAllVisible = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PiwikTracker.sharedInstance()?.wmf_logView(self)
        NSUserActivity.wmf_makeActive(NSUserActivity.wmf_savedPagesView())
    }
    
    override var analyticsName: String {
        return "Saved"
    }
    
    override var emptyViewType: WMFEmptyViewType {
        return .noSavedPages
    }
    
    override func deleteAll() {
        dataStore.savedPageList.removeAllEntries()
    }
    
    override open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: reuseIdentifier, for: indexPath)
        guard let savedArticleCell = cell as? SavedArticleCollectionViewCell else {
            return cell
        }
        configure(cell: savedArticleCell, forItemAt: indexPath, layoutOnly: false)
        return cell
    }
    
    override func configure(cell: ArticleRightAlignedImageCollectionViewCell, forItemAt indexPath: IndexPath, layoutOnly: Bool) {
        super.configure(cell: cell, forItemAt: indexPath, layoutOnly: layoutOnly)
        guard let article = article(at: indexPath) else {
            return
        }
        if let readingList = delegate?.readingList(for: article) {
            print(readingList)
        }
    }
}
