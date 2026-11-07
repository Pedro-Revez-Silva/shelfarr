package org.shelfarr.app.reader

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
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
import kotlinx.coroutines.launch
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.epub.css.FontStyle
import org.readium.r2.navigator.epub.css.FontWeight
import org.readium.r2.navigator.input.InputListener
import org.readium.r2.navigator.input.TapEvent
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Hosts Readium's EPUB navigator with native Compose chrome laid over it.
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
                                viewModel.useOtherPlace()?.let { navigator?.go(it, animated = false) }
                            }
                        },
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
                    if (state is ReaderState.Ready && navigator == null) attachNavigator(state)
                }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.settings.collect { settings ->
                    navigator?.submitPreferences(settings.toPreferences())
                    window.decorView.setBackgroundColor(settings.theme.page.toInt())
                    updateBars()
                }
            }
        }
        updateBars()
    }

    private fun attachNavigator(state: ReaderState.Ready) {
        supportFragmentManager.fragmentFactory = state.navigatorFactory.createFragmentFactory(
            initialLocator = state.initialLocator,
            initialPreferences = viewModel.settings.value.toPreferences(),
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

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                fragment.currentLocator.collect(viewModel::onLocatorChanged)
            }
        }
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
        if (chromeVisible || navigator == null) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
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

        fun intent(context: Context, publicationId: String): Intent =
            Intent(context, ReaderActivity::class.java).putExtra(EXTRA_PUBLICATION, publicationId)
    }
}
