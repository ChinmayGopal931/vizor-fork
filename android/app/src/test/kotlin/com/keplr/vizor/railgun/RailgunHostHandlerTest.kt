package com.keplr.vizor.railgun

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoMoreInteractions
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

// Dart's bootstrap asks `supported` before the first frame, so it must answer at once.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class RailgunHostHandlerTest {
    @Test
    fun everyAndroidBuildSupportsThePage() {
        val handler = RailgunHostHandler(RuntimeEnvironment.getApplication(), debuggable = false)
        val result = mock(MethodChannel.Result::class.java)

        handler.handle(MethodCall("supported", null), result)

        verify(result).success(true)
        verifyNoMoreInteractions(result)
    }
}
