package org.shelfarr.app.reader

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.ComposeView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentContainerView
import androidx.fragment.app.commitNow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.CreationExtras
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.epub.css.FontStyle
import org.readium.r2.navigator.epub.css.FontWeight
import org.readium.r2.navigator.input.InputListener
import org.readium.r2.navigator.input.TapEvent
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Hosts Readium's EPUB navigator with native Compose chrome laid over it, or, for a PDF
 * or comic, the Compose page reader on its own.
 *
 * The reader always rebuilds from the saved locator, so fragment state is
 * deliberately not restored after process death (Readium cannot restore a
 * `Publication` from a bundle).
 */
@OptIn(ExperimentalReadiumApi::class)
class ReaderActivity : FragmentActivity() {
    private val publicationId: String by lazy { requireNotNull(intent.getStringExtra(EXTRA_PUBLICATION)) }

    private val viewModel: ReaderViewModel by viewModels {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                ReaderViewModel(application as Application, publicationId) as T
        }
    }

    private var navigator: EpubNavigatorFragment? = null
    private var chromeVisible by mutableStateOf(false)
    private lateinit var navigatorHost: FragmentContainerView

    override fun onCreate(savedInstanceState: Bundle?) {
        // No fragment restore: see the class comment.
        super.onCreate(null)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) window.isNavigationBarContrastEnforced = false

        navigatorHost = FragmentContainerView(this).apply { id = R.id.reader_navigator }
        val chrome = ComposeView(this).apply {
            setContent {
                val appearance by (application as ShelfarrApplication).container.appearance.collectAsState()
                ShelfarrTheme(appearance) {
                    ReaderScreen(
                        viewModel = viewModel,
                        chromeVisible = chromeVisible,
                        onToggleChrome = ::toggleChrome,
                        onClose = ::finish,
                        onGo = { link -> navigator?.go(link, animated = false); hideChrome() },
                        onScrub = { fraction ->
                            lifecycleScope.launch {
                                viewModel.locatorFor(fraction)?.let { navigator?.go(it, animated = false) }
                            }
                        },
                        onUseOtherPlace = {
                            lifecycleScope.launch {
                                viewModel.useOtherPlace()?.let { locator ->
                                    viewModel.onDisplayMove(locator.href.toString())
                                    navigator?.go(locator, animated = false)
                                }
                            }
                        },
                        narration = narrationActions,
                    )
                }
            }
        }
        setContentView(
            FrameLayout(this).apply {
                addView(navigatorHost, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                addView(chrome, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            },
        )
        // Text stays clear of the notch and gesture areas, whatever the chrome is doing.
        ViewCompat.setOnApplyWindowInsetsListener(navigatorHost) { view, insets ->
            val safe = insets.getInsets(WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.systemGestures())
            view.setPadding(safe.left, 0, safe.right, 0)
            insets
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.CREATED) {
                viewModel.state.collect { state ->
                    // Only an EPUB gets Readium's navigator. PDFs and comics are drawn by the Compose pager.
                    if (state is ReaderState.Ready && navigator == null) attachNavigator(state)
                    updateBars()
                }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                var applied: ReaderSettings? = null
                viewModel.settings.collect { settings ->
                    // New text settings re-lay out the page; what Readium reports next isn't reading.
                    if (applied != null && applied?.toPreferences() != settings.toPreferences()) viewModel.onLayoutChanged()
                    applied = settings
                    navigator?.submitPreferences(settings.toPreferences())
                    window.decorView.setBackgroundColor(settings.theme.page.toInt())
                    updateBars()
                }
            }
        }
        updateBars()
    }

    private fun attachNavigator(state: ReaderState.Ready) {
        // currentLocator starts with the requested place, before a page exists. Pagination
        // reports actual layout even when that locator equals the requested one.
        val renderedLocations = MutableStateFlow<Locator?>(null)
        supportFragmentManager.fragmentFactory = state.navigatorFactory.createFragmentFactory(
            initialLocator = state.initialLocator,
            initialPreferences = viewModel.settings.value.toPreferences(),
            paginationListener = object : EpubNavigatorFragment.PaginationListener {
                override fun onPageChanged(pageIndex: Int, totalPages: Int, locator: Locator) {
                    renderedLocations.value = locator
                }
            },
            configuration = EpubNavigatorFragment.Configuration {
                servedAssets = listOf("fonts/.*")
                addFontFamilyDeclaration(FontFamily("Newsreader")) {
                    addFontFace {
                        addSource("fonts/Newsreader-Regular.ttf")
                        setFontStyle(FontStyle.NORMAL)
                        setFontWeight(FontWeight.NORMAL)
                    }
                    addFontFace {
                        addSource("fonts/Newsreader-Italic.ttf")
                        setFontStyle(FontStyle.ITALIC)
                        setFontWeight(FontWeight.NORMAL)
                    }
                    addFontFace {
                        addSource("fonts/Newsreader-SemiBold.ttf")
                        setFontStyle(FontStyle.NORMAL)
                        setFontWeight(FontWeight.BOLD)
                    }
                }
            },
        )
        supportFragmentManager.commitNow {
            add(navigatorHost.id, EpubNavigatorFragment::class.java, Bundle(), NAVIGATOR_TAG)
        }
        val fragment = supportFragmentManager.findFragmentByTag(NAVIGATOR_TAG) as EpubNavigatorFragment
        navigator = fragment

        fragment.addInputListener(DirectionalNavigationAdapter(fragment, animatedTransition = true))
        fragment.addInputListener(object : InputListener {
            override fun onTap(event: TapEvent): Boolean {
                toggleChrome()
                return true
            }
        })

        var lastReported: Locator? = null
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                renderedLocations.filterNotNull().collect { locator ->
                    // Resubscribing after backgrounding is not another page turn.
                    if (locator != lastReported) {
                        lastReported = locator
                        viewModel.onLocatorChanged(locator)
                    }
                }
            }
        }
        // The element being narrated, drawn by Readium under the text in the page's own colours.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(viewModel.narrationHighlight, viewModel.settings) { locator, settings -> locator to settings.theme }
                    .distinctUntilChanged()
                    .collect { (locator, theme) ->
                        val decoration = locator?.let {
                            Decoration(id = NARRATION_DECORATION, locator = it, style = Decoration.Style.Highlight(tint = theme.narration.toInt(), isActive = false))
                        }
                        fragment.applyDecorations(listOfNotNull(decoration), NARRATION_GROUP)
                    }
            }
        }
        // Page-follow and requested places: display only, never reading.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.narrationShow.collectLatest { request -> show(fragment, request) }
            }
        }
    }

    private suspend fun show(fragment: EpubNavigatorFragment, request: ReadAlongCoordinator.ShowRequest) {
        val target = request.locator
        val href = target.href.toString()
        if (request.onlyIfHidden && fragment.currentLocator.value.href.toString() == href) {
            val id = target.locations.fragments.firstOrNull() ?: return
            if (NarrationScripts.decode(fragment.evaluateJavascript(NarrationScripts.isVisible(id))) == "1") return
        }
        viewModel.onDisplayMove(href)
        fragment.go(target, animated = false)
    }

    /** What the page on screen shows of the narration: the first narrated element in view, or the next one after it. */
    private suspend fun pageCues(): PageCues? {
        val fragment = navigator ?: return null
        val href = fragment.currentLocator.value.href.toString()
        val ids = viewModel.narrationFragments(href)
        if (ids.isEmpty()) return PageCues(href, null, null)
        val found = NarrationScripts.decode(fragment.evaluateJavascript(NarrationScripts.pageCues(ids))).orEmpty()
        return when {
            found.startsWith("v:") -> PageCues(href, found.removePrefix("v:"), null)
            found.startsWith("a:") -> PageCues(href, null, found.removePrefix("a:"))
            else -> PageCues(href, null, null)
        }
    }

    /** The narration controls as the reading screen calls them; visible to device tests. */
    internal val narrationActions = object : NarrationActions {
        override fun toggle() {
            lifecycleScope.launch {
                val page = if (viewModel.narrationNeedsPage) pageCues() else null
                viewModel.toggleNarration(page)
            }
        }

        override fun skip(back: Boolean) { viewModel.skipNarration(back) }
        override fun setSpeed(speed: Float) { viewModel.setNarrationSpeed(speed) }
        override fun setFollow(follow: Boolean) { viewModel.setFollowNarration(follow) }
        override fun backToNarration() { viewModel.backToNarration() }
        override fun useAudiobookPlace() { viewModel.useAudiobookPlace() }
        override fun dismissAudiobookPlace() { viewModel.dismissAudiobookPlace() }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        // Rotation and resizing re-lay out the page: not reading.
        viewModel.onLayoutChanged()
        super.onConfigurationChanged(newConfig)
    }

    private fun toggleChrome() {
        chromeVisible = !chromeVisible
        updateBars()
    }

    private fun hideChrome() {
        chromeVisible = false
        updateBars()
    }

    private fun updateBars() {
        val theme = viewModel.settings.value.theme
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.isAppearanceLightStatusBars = theme != ReaderTheme.NIGHT
        controller.isAppearanceLightNavigationBars = theme != ReaderTheme.NIGHT
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        val immersive = navigator != null || viewModel.state.value is ReaderState.Paged
        if (chromeVisible || !immersive) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    /**
     * Hardware keys turn PDF and comic pages: Page Up/Down, Space (Shift+Space back) and
     * the arrows. This only sees keys no focused control used, so arrows still move focus
     * between the controls while they are shown. A turn starts from the page on screen,
     * even one that couldn't be drawn, and is saved only once the new page is seen.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (viewModel.state.value !is ReaderState.Paged) return super.onKeyDown(keyCode, event)
        val delta = when (keyCode) {
            KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT -> 1
            KeyEvent.KEYCODE_PAGE_UP, KeyEvent.KEYCODE_DPAD_LEFT -> -1
            KeyEvent.KEYCODE_SPACE -> if (event.isShiftPressed) -1 else 1
            else -> return super.onKeyDown(keyCode, event)
        }
        viewModel.turnPage(delta)
        return true
    }

    override fun onPause() {
        viewModel.flush()
        super.onPause()
    }

    override fun onStop() {
        viewModel.flush()
        super.onStop()
    }

    companion object {
        private const val EXTRA_PUBLICATION = "publication"
        private const val NAVIGATOR_TAG = "navigator"
        private const val NARRATION_GROUP = "read-along"
        private const val NARRATION_DECORATION = "narration"

        fun intent(context: Context, publicationId: String): Intent =
            Intent(context, ReaderActivity::class.java).putExtra(EXTRA_PUBLICATION, publicationId)
    }
}
