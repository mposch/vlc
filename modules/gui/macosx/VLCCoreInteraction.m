/*****************************************************************************
 * CoreInteraction.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2011-2019 Felix Paul Kühne
 *
 * Authors: Felix Paul Kühne <fkuehne -at- videolan -dot- org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCCoreInteraction.h"
#import "VLCMain.h"
#import "VLCOpenWindowController.h"
#import "VLCPlaylist.h"
#import <vlc_strings.h>
#import <vlc_url.h>
#import <vlc_modules.h>
#import <vlc_plugin.h>
#import <vlc_actions.h>
#import "VLCClickerManager.h"

static int BossCallback(vlc_object_t *p_this, const char *psz_var,
                        vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[VLCCoreInteraction sharedInstance] pause];
            [[NSApplication sharedApplication] hide:nil];
        });

        return VLC_SUCCESS;
    }
}

@interface VLCCoreInteraction ()
{
    int i_currentPlaybackRate;
    vlc_tick_t timeA, timeB;

    float f_maxVolume;

    NSArray *_usedHotkeys;

    VLCClickerManager *_clickerManager;
}
@end

@implementation VLCCoreInteraction

#pragma mark - Initialization

+ (VLCCoreInteraction *)sharedInstance
{
    static VLCCoreInteraction *sharedInstance = nil;
    static dispatch_once_t pred;

    dispatch_once(&pred, ^{
        sharedInstance = [VLCCoreInteraction new];
    });

    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        intf_thread_t *p_intf = getIntf();

        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                          selector:@selector(applicationWillTerminate:)
                              name:NSApplicationWillTerminateNotification
                            object:nil];

        _clickerManager = [[VLCClickerManager alloc] init];

        var_AddCallback(pl_Get(p_intf), "intf-boss", BossCallback, (__bridge void *)self);
    }
    return self;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    // Dealloc is never called because this is a singleton, so we should cleanup manually before termination
    intf_thread_t *p_intf = getIntf();
    var_DelCallback(pl_Get(p_intf), "intf-boss", BossCallback, (__bridge void *)self);
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    _clickerManager = nil;
    _usedHotkeys = nil;
}

#pragma mark - Playback Controls

- (void)play
{
    playlist_t *p_playlist = pl_Get(getIntf());
    playlist_Play(p_playlist);
}

- (void)playOrPause
{
    input_thread_t *p_input = pl_CurrentInput(getIntf());
    playlist_t *p_playlist = pl_Get(getIntf());

    if (p_input) {
        playlist_TogglePause(p_playlist);
        vlc_object_release(p_input);
    } else {
        PLRootType root = [[[[VLCMain sharedInstance] playlist] model] currentRootType];
        VLCMain *mainInstance = [VLCMain sharedInstance];
        if ([[mainInstance playlist] isSelectionEmpty] && (root == ROOT_TYPE_PLAYLIST))
            [[mainInstance open] openFileGeneric];
        else
            [[mainInstance playlist] playItem:nil];
    }
}

- (void)pause
{
    playlist_t *p_playlist = pl_Get(getIntf());
    playlist_Pause(p_playlist);
}

- (void)stop
{
    playlist_Stop(pl_Get(getIntf()));
}

- (void)faster
{
    var_TriggerCallback(pl_Get(getIntf()), "rate-faster");
}

- (void)slower
{
    var_TriggerCallback(pl_Get(getIntf()), "rate-slower");
}

- (void)normalSpeed
{
    var_SetFloat(pl_Get(getIntf()), "rate", 1.);
}

- (void)toggleRecord
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    input_thread_t * p_input;
    p_input = pl_CurrentInput(p_intf);
    if (p_input) {
        var_ToggleBool(p_input, "record");
        vlc_object_release(p_input);
    }
}

- (void)setPlaybackRate:(int)i_value
{
    playlist_t * p_playlist = pl_Get(getIntf());

    double speed = pow(2, (double)i_value / 17);
    int rate = INPUT_RATE_DEFAULT / speed;
    if (i_currentPlaybackRate != rate)
        var_SetFloat(p_playlist, "rate", (float)INPUT_RATE_DEFAULT / (float)rate);
    i_currentPlaybackRate = rate;
}

- (int)playbackRate
{
    float f_rate;

    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return 0;

    input_thread_t * p_input;
    p_input = pl_CurrentInput(p_intf);
    if (p_input) {
        f_rate = var_GetFloat(p_input, "rate");
        vlc_object_release(p_input);
    } else {
        playlist_t * p_playlist = pl_Get(getIntf());
        f_rate = var_GetFloat(p_playlist, "rate");
    }

    double value = 17 * log(f_rate) / log(2.);
    int returnValue = (int) ((value > 0) ? value + .5 : value - .5);

    if (returnValue < -34)
        returnValue = -34;
    else if (returnValue > 34)
        returnValue = 34;

    i_currentPlaybackRate = returnValue;
    return returnValue;
}

- (void)previous
{
    playlist_Prev(pl_Get(getIntf()));
}

- (void)next
{
    playlist_Next(pl_Get(getIntf()));
}

- (NSInteger)durationOfCurrentPlaylistItem
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return 0;

    input_thread_t * p_input = pl_CurrentInput(p_intf);
    vlc_tick_t i_duration;
    if (!p_input)
        return -1;

    i_duration = var_GetInteger(p_input, "length");
    vlc_object_release(p_input);

    return SEC_FROM_VLC_TICK(i_duration);
}

- (NSURL*)URLOfCurrentPlaylistItem
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return nil;

    input_thread_t *p_input = pl_CurrentInput(p_intf);
    if (!p_input)
        return nil;

    input_item_t *p_item = input_GetItem(p_input);
    if (!p_item) {
        vlc_object_release(p_input);
        return nil;
    }

    char *psz_uri = input_item_GetURI(p_item);
    if (!psz_uri) {
        vlc_object_release(p_input);
        return nil;
    }

    NSURL *o_url;
    o_url = [NSURL URLWithString:toNSStr(psz_uri)];
    free(psz_uri);
    vlc_object_release(p_input);

    return o_url;
}

- (NSString*)nameOfCurrentPlaylistItem
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return nil;

    input_thread_t *p_input = pl_CurrentInput(p_intf);
    if (!p_input)
        return nil;

    input_item_t *p_item = input_GetItem(p_input);
    if (!p_item) {
        vlc_object_release(p_input);
        return nil;
    }

    char *psz_uri = input_item_GetURI(p_item);
    if (!psz_uri) {
        vlc_object_release(p_input);
        return nil;
    }

    NSString *o_name;
    char *format = var_InheritString(getIntf(), "input-title-format");
    if (format) {
        char *formated = vlc_strfinput(p_input, NULL, format);
        free(format);
        o_name = toNSStr(formated);
        free(formated);
    }

    NSURL * o_url = [NSURL URLWithString:toNSStr(psz_uri)];
    free(psz_uri);

    if (!o_name) {
        if ([o_url isFileURL])
            o_name = [[NSFileManager defaultManager] displayNameAtPath:[o_url path]];
        else
            o_name = [o_url absoluteString];
    }
    vlc_object_release(p_input);
    return o_name;
}

- (void)jumpWithValue:(char *)p_value forward:(BOOL)b_value
{
    input_thread_t *p_input = pl_CurrentInput(getIntf());
    if (!p_input)
        return;

    int64_t i_interval = var_InheritInteger( p_input, p_value );
    if (i_interval > 0) {
        vlc_tick_t val = vlc_tick_from_sec( i_interval );
        if (!b_value)
            val = val * -1;
        var_SetInteger( p_input, "time-offset", val );
    }
    vlc_object_release(p_input);
}

- (void)forwardExtraShort
{
    [self jumpWithValue:"extrashort-jump-size" forward:YES];
}

- (void)backwardExtraShort
{
    [self jumpWithValue:"extrashort-jump-size" forward:NO];
}

- (void)forwardShort
{
    [self jumpWithValue:"short-jump-size" forward:YES];
}

- (void)backwardShort
{
    [self jumpWithValue:"short-jump-size" forward:NO];
}

- (void)forwardMedium
{
    [self jumpWithValue:"medium-jump-size" forward:YES];
}

- (void)backwardMedium
{
    [self jumpWithValue:"medium-jump-size" forward:NO];
}

- (void)forwardLong
{
    [self jumpWithValue:"long-jump-size" forward:YES];
}

- (void)backwardLong
{
    [self jumpWithValue:"long-jump-size" forward:NO];
}

- (void)shuffle
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    vlc_value_t val;
    playlist_t * p_playlist = pl_Get(p_intf);
    vout_thread_t *p_vout = getVout();

    var_Get(p_playlist, "random", &val);
    val.b_bool = !val.b_bool;
    var_Set(p_playlist, "random", val);
    if (val.b_bool) {
        if (p_vout) {
            vout_OSDMessage(p_vout, VOUT_SPU_CHANNEL_OSD, "%s", _("Random On"));
            vlc_object_release(p_vout);
        }
        config_PutInt("random", 1);
    }
    else
    {
        if (p_vout) {
            vout_OSDMessage(p_vout, VOUT_SPU_CHANNEL_OSD, "%s", _("Random Off"));
            vlc_object_release(p_vout);
        }
        config_PutInt("random", 0);
    }
}

- (void)repeatAll
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_t * p_playlist = pl_Get(p_intf);

    var_SetBool(p_playlist, "repeat", NO);
    var_SetBool(p_playlist, "loop", YES);
    config_PutInt("repeat", NO);
    config_PutInt("loop", YES);

    vout_thread_t *p_vout = getVout();
    if (p_vout) {
        vout_OSDMessage(p_vout, VOUT_SPU_CHANNEL_OSD, "%s", _("Repeat All"));
        vlc_object_release(p_vout);
    }
}

- (void)repeatOne
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_t * p_playlist = pl_Get(p_intf);

    var_SetBool(p_playlist, "repeat", YES);
    var_SetBool(p_playlist, "loop", NO);
    config_PutInt("repeat", YES);
    config_PutInt("loop", NO);

    vout_thread_t *p_vout = getVout();
    if (p_vout) {
        vout_OSDMessage(p_vout, VOUT_SPU_CHANNEL_OSD, "%s", _("Repeat One"));
        vlc_object_release(p_vout);
    }
}

- (void)repeatOff
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_t * p_playlist = pl_Get(p_intf);

    var_SetBool(p_playlist, "repeat", NO);
    var_SetBool(p_playlist, "loop", NO);
    config_PutInt("repeat", NO);
    config_PutInt("loop", NO);

    vout_thread_t *p_vout = getVout();
    if (p_vout) {
        vout_OSDMessage(p_vout, VOUT_SPU_CHANNEL_OSD, "%s", _("Repeat Off"));
        vlc_object_release(p_vout);
    }
}

- (void)setAtoB
{
    if (!timeA) {
        input_thread_t * p_input = pl_CurrentInput(getIntf());
        if (p_input) {
            msg_Dbg(getIntf(), "Setting A value");

            timeA = var_GetInteger(p_input, "time");
            vlc_object_release(p_input);
        }
    } else if (!timeB) {
        input_thread_t * p_input = pl_CurrentInput(getIntf());
        if (p_input) {
            msg_Dbg(getIntf(), "Setting B value");

            timeB = var_GetInteger(p_input, "time");
            vlc_object_release(p_input);
        }
    } else
        [self resetAtoB];
}

- (void)resetAtoB
{
    msg_Dbg(getIntf(), "Resetting A to B values");
    timeA = 0;
    timeB = 0;
}

- (void)updateAtoB
{
    if (timeB) {
        input_thread_t * p_input = pl_CurrentInput(getIntf());
        if (p_input) {
            vlc_tick_t currentTime = var_GetInteger(p_input, "time");
            if ( currentTime >= timeB || currentTime < timeA)
                var_SetInteger(p_input, "time", timeA);
            vlc_object_release(p_input);
        }
    }
}

- (void)jumpToTime:(vlc_tick_t)time
{
    input_thread_t * p_input = pl_CurrentInput(getIntf());
    if (p_input) {
        var_SetInteger(p_input, "time", time);
        vlc_object_release(p_input);
    }
}

- (void)volumeUp
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_VolumeUp(pl_Get(p_intf), 1, NULL);
}

- (void)volumeDown
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_VolumeDown(pl_Get(p_intf), 1, NULL);
}

- (void)toggleMute
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    playlist_MuteToggle(pl_Get(p_intf));
}

- (BOOL)mute
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return NO;

    BOOL b_is_muted = NO;
    b_is_muted = playlist_MuteGet(pl_Get(p_intf)) > 0;

    return b_is_muted;
}

- (int)volume
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return 0;

    float volume = playlist_VolumeGet(pl_Get(p_intf));

    return (int)lroundf(volume * AOUT_VOLUME_DEFAULT);
}

- (void)setVolume: (int)i_value
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    if (i_value >= self.maxVolume)
        i_value = self.maxVolume;

    float f_value = i_value / (float)AOUT_VOLUME_DEFAULT;

    playlist_VolumeSet(pl_Get(p_intf), f_value);
}

- (float)maxVolume
{
    if (f_maxVolume == 0.) {
        f_maxVolume = (float)var_InheritInteger(getIntf(), "macosx-max-volume") / 100. * AOUT_VOLUME_DEFAULT;
    }

    return f_maxVolume;
}

- (void)addSubtitlesToCurrentInput:(NSArray *)paths
{
    input_thread_t * p_input = pl_CurrentInput(getIntf());
    if (!p_input)
        return;

    NSUInteger count = [paths count];
    for (int i = 0; i < count ; i++) {
        char *mrl = vlc_path2uri([[[paths objectAtIndex:i] path] UTF8String], NULL);
        if (!mrl)
            continue;
        msg_Dbg(getIntf(), "loading subs from %s", mrl);

        int i_result = input_AddSlave(p_input, SLAVE_TYPE_SPU, mrl, true, true, true);
        if (i_result != VLC_SUCCESS)
            msg_Err(getIntf(), "unable to load subtitles from '%s'", mrl);
        free(mrl);
    }
    vlc_object_release(p_input);
}

- (void)showPosition
{
    input_thread_t *p_input = pl_CurrentInput(getIntf());
    if (p_input != NULL) {
        vout_thread_t *p_vout = input_GetVout(p_input);
        if (p_vout != NULL) {
            var_SetInteger(getIntf()->obj.libvlc, "key-action", ACTIONID_POSITION);
            vlc_object_release(p_vout);
        }
        vlc_object_release(p_input);
    }
}

#pragma mark - video output stuff

- (void)setAspectRatioIsLocked:(BOOL)b_value
{
    config_PutInt("macosx-lock-aspect-ratio", b_value);
}

- (BOOL)aspectRatioIsLocked
{
    return config_GetInt("macosx-lock-aspect-ratio");
}

- (void)toggleFullscreen
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return;

    vout_thread_t *p_vout = getVoutForActiveWindow();
    if (p_vout) {
        BOOL b_fs = var_ToggleBool(p_vout, "fullscreen");
        var_SetBool(pl_Get(p_intf), "fullscreen", b_fs);
        vlc_object_release(p_vout);
    } else { // e.g. lion fullscreen toggle
        BOOL b_fs = var_ToggleBool(pl_Get(p_intf), "fullscreen");
        [[[VLCMain sharedInstance] voutProvider] setFullscreen:b_fs forWindow:nil withAnimation:YES];
    }
}

#pragma mark - menu navigation
- (void)menuFocusActivate
{
    input_thread_t *p_input_thread = pl_CurrentInput(getIntf());
    if (p_input_thread == NULL)
        return;

    input_Control(p_input_thread, INPUT_NAV_ACTIVATE, NULL );
    vlc_object_release(p_input_thread);
}

- (void)moveMenuFocusLeft
{
    input_thread_t *p_input_thread = pl_CurrentInput(getIntf());
    if (p_input_thread == NULL)
        return;

    input_Control(p_input_thread, INPUT_NAV_LEFT, NULL );
    vlc_object_release(p_input_thread);
}

- (void)moveMenuFocusRight
{
    input_thread_t *p_input_thread = pl_CurrentInput(getIntf());
    if (p_input_thread == NULL)
        return;

    input_Control(p_input_thread, INPUT_NAV_RIGHT, NULL );
    vlc_object_release(p_input_thread);
}

- (void)moveMenuFocusUp
{
    input_thread_t *p_input_thread = pl_CurrentInput(getIntf());
    if (p_input_thread == NULL)
        return;

    input_Control(p_input_thread, INPUT_NAV_UP, NULL );
    vlc_object_release(p_input_thread);
}

- (void)moveMenuFocusDown
{
    input_thread_t *p_input_thread = pl_CurrentInput(getIntf());
    if (p_input_thread == NULL)
        return;

    input_Control(p_input_thread, INPUT_NAV_DOWN, NULL );
    vlc_object_release(p_input_thread);
}

#pragma mark -
#pragma mark Key Shortcuts

/*****************************************************************************
 * hasDefinedShortcutKey: Check to see if the key press is a defined VLC
 * shortcut key.  If it is, pass it off to VLC for handling and return YES,
 * otherwise ignore it and return NO (where it will get handled by Cocoa).
 *****************************************************************************/

- (BOOL)keyEvent:(NSEvent *)o_event
{
    BOOL eventHandled = NO;
    NSString * characters = [o_event charactersIgnoringModifiers];
    if ([characters length] > 0) {
        unichar key = [characters characterAtIndex: 0];

        if (key) {
            input_thread_t * p_input = pl_CurrentInput(getIntf());
            if (p_input != NULL) {
                vout_thread_t *p_vout = input_GetVout(p_input);

                if (p_vout != NULL) {
                    /* Escape */
                    if (key == (unichar) 0x1b) {
                        if (var_GetBool(p_vout, "fullscreen")) {
                            [self toggleFullscreen];
                            eventHandled = YES;
                        }
                    }
                    vlc_object_release(p_vout);
                }
                vlc_object_release(p_input);
            }
        }
    }
    return eventHandled;
}

- (BOOL)hasDefinedShortcutKey:(NSEvent *)o_event force:(BOOL)b_force
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return NO;

    unichar key = 0;
    vlc_value_t val;
    unsigned int i_pressed_modifiers = 0;

    val.i_int = 0;
    i_pressed_modifiers = [o_event modifierFlags];

    if (i_pressed_modifiers & NSControlKeyMask)
        val.i_int |= KEY_MODIFIER_CTRL;

    if (i_pressed_modifiers & NSAlternateKeyMask)
        val.i_int |= KEY_MODIFIER_ALT;

    if (i_pressed_modifiers & NSShiftKeyMask)
        val.i_int |= KEY_MODIFIER_SHIFT;

    if (i_pressed_modifiers & NSCommandKeyMask)
        val.i_int |= KEY_MODIFIER_COMMAND;

    NSString * characters = [o_event charactersIgnoringModifiers];
    if ([characters length] > 0) {
        key = [[characters lowercaseString] characterAtIndex: 0];

        /* handle Lion's default key combo for fullscreen-toggle in addition to our own hotkeys */
        if (key == 'f' && i_pressed_modifiers & NSControlKeyMask && i_pressed_modifiers & NSCommandKeyMask) {
            [self toggleFullscreen];
            return YES;
        }

        if (!b_force) {
            switch(key) {
                case NSDeleteCharacter:
                case NSDeleteFunctionKey:
                case NSDeleteCharFunctionKey:
                case NSBackspaceCharacter:
                case NSUpArrowFunctionKey:
                case NSDownArrowFunctionKey:
                case NSEnterCharacter:
                case NSCarriageReturnCharacter:
                    return NO;
            }
        }

        val.i_int |= CocoaKeyToVLC(key);

        BOOL b_found_key = NO;
        NSUInteger numberOfUsedHotkeys = [_usedHotkeys count];
        for (NSUInteger i = 0; i < numberOfUsedHotkeys; i++) {
            NSString *str = [_usedHotkeys objectAtIndex:i];
            unsigned int i_keyModifiers = VLCModifiersToCocoa(str);

            if ([[characters lowercaseString] isEqualToString: VLCKeyToString(str)] &&
                (i_keyModifiers & NSShiftKeyMask)     == (i_pressed_modifiers & NSShiftKeyMask) &&
                (i_keyModifiers & NSControlKeyMask)   == (i_pressed_modifiers & NSControlKeyMask) &&
                (i_keyModifiers & NSAlternateKeyMask) == (i_pressed_modifiers & NSAlternateKeyMask) &&
                (i_keyModifiers & NSCommandKeyMask)   == (i_pressed_modifiers & NSCommandKeyMask)) {
                b_found_key = YES;
                break;
            }
        }

        if (b_found_key) {
            var_SetInteger(p_intf->obj.libvlc, "key-pressed", val.i_int);
            return YES;
        }
    }

    return NO;
}

- (void)updateCurrentlyUsedHotkeys
{
    NSMutableArray *mutArray = [[NSMutableArray alloc] init];
    /* Get the main Module */
    module_t *p_main = module_get_main();
    assert(p_main);
    unsigned confsize;
    module_config_t *p_config;

    p_config = module_config_get (p_main, &confsize);

    for (size_t i = 0; i < confsize; i++) {
        module_config_t *p_item = p_config + i;

        if (CONFIG_ITEM(p_item->i_type) && p_item->psz_name != NULL
            && !strncmp(p_item->psz_name , "key-", 4)
            && !EMPTY_STR(p_item->psz_text)) {
            if (p_item->value.psz)
                [mutArray addObject:toNSStr(p_item->value.psz)];
        }
    }
    module_config_free (p_config);

    _usedHotkeys = [[NSArray alloc] initWithArray:mutArray copyItems:YES];
}

@end
