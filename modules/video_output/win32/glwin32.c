/*****************************************************************************
 * glwin32.c: Windows OpenGL provider
 *****************************************************************************
 * Copyright (C) 2001-2009 VLC authors and VideoLAN
 *
 * Authors: Gildas Bazin <gbazin@videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <assert.h>

#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_vout_display.h>

#include <windows.h>
#include <versionhelpers.h>

#define GLEW_STATIC
#include "../opengl/vout_helper.h"

#include "common.h"

/*****************************************************************************
 * Module descriptor
 *****************************************************************************/
static int  Open (vout_display_t *, const vout_display_cfg_t *,
                  video_format_t *, vlc_video_context *);
static void Close(vout_display_t *);

vlc_module_begin()
    set_category(CAT_VIDEO)
    set_subcategory(SUBCAT_VIDEO_VOUT)
    set_shortname("OpenGL")
    set_description(N_("OpenGL video output for Windows"))
    set_capability("vout display", 275)
    add_shortcut("glwin32", "opengl")
    set_callbacks(Open, Close)
    add_glopts()
vlc_module_end()

/*****************************************************************************
 * Local prototypes.
 *****************************************************************************/
struct vout_display_sys_t
{
    vout_display_sys_win32_t sys;

    vlc_gl_t              *gl;
    vout_display_opengl_t *vgl;
};

static picture_pool_t *Pool  (vout_display_t *, unsigned);
static void           Prepare(vout_display_t *, picture_t *, subpicture_t *, vlc_tick_t);
static void           Display(vout_display_t *, picture_t *);
static void           Manage (vout_display_t *);

static int Control(vout_display_t *vd, int query, va_list args)
{
    vout_display_sys_t *sys = vd->sys;

    if (query == VOUT_DISPLAY_CHANGE_VIEWPOINT)
        return vout_display_opengl_SetViewpoint(sys->vgl,
            &va_arg (args, const vout_display_cfg_t* )->viewpoint);

    return CommonControl(vd, query, args);
}

static const struct vout_window_operations embedVideoWindow_Ops =
{
};

static vout_window_t *EmbedVideoWindow_Create(vout_display_t *vd)
{
    vout_display_sys_t *sys = vd->sys;

    if (!sys->sys.hvideownd)
        return NULL;

    vout_window_t *wnd = vlc_object_create(vd, sizeof(vout_window_t));
    if (!wnd)
        return NULL;

    wnd->type = VOUT_WINDOW_TYPE_HWND;
    wnd->handle.hwnd = sys->sys.hvideownd;
    wnd->ops = &embedVideoWindow_Ops;
    return wnd;
}

/**
 * It creates an OpenGL vout display.
 */
static int Open(vout_display_t *vd, const vout_display_cfg_t *cfg,
                video_format_t *fmtp, vlc_video_context *context)
{
    vout_display_sys_t *sys;

    /* do not use OpenGL on XP unless forced */
    if(!vd->obj.force && !IsWindowsVistaOrGreater())
        return VLC_EGENERIC;

    /* Allocate structure */
    vd->sys = sys = calloc(1, sizeof(*sys));
    if (!sys)
        return VLC_ENOMEM;

    /* */
    if (CommonInit(vd, false, cfg))
        goto error;

    if (!sys->sys.b_windowless)
        EventThreadUpdateTitle(sys->sys.event, VOUT_TITLE " (OpenGL output)");

    vout_window_t *surface = EmbedVideoWindow_Create(vd);
    if (!surface)
        goto error;

    char *modlist = var_InheritString(surface, "gl");
    sys->gl = vlc_gl_Create(cfg, VLC_OPENGL, modlist);
    free(modlist);
    if (!sys->gl)
    {
        vlc_object_release(surface);
        goto error;
    }

    vlc_gl_Resize (sys->gl, cfg->display.width, cfg->display.height);

    video_format_t fmt = *fmtp;
    const vlc_fourcc_t *subpicture_chromas;
    if (vlc_gl_MakeCurrent (sys->gl))
        goto error;
    sys->vgl = vout_display_opengl_New(&fmt, &subpicture_chromas, sys->gl,
                                       &cfg->viewpoint);
    vlc_gl_ReleaseCurrent (sys->gl);
    if (!sys->vgl)
        goto error;

    /* Setup vout_display now that everything is fine */
    vd->info.has_double_click = true;
    vd->info.subpicture_chromas = subpicture_chromas;

    *fmtp    = fmt;

    vd->pool    = Pool;
    vd->prepare = Prepare;
    vd->display = Display;
    vd->control = Control;

    return VLC_SUCCESS;

error:
    Close(vd);
    return VLC_EGENERIC;
}

/**
 * It destroys an OpenGL vout display.
 */
static void Close(vout_display_t *vd)
{
    vout_display_sys_t *sys = vd->sys;
    vlc_gl_t *gl = sys->gl;

    if (gl)
    {
        vout_window_t *surface = gl->surface;
        if (sys->vgl)
        {
            vlc_gl_MakeCurrent (gl);
            vout_display_opengl_Delete(sys->vgl);
            vlc_gl_ReleaseCurrent (gl);
        }
        vlc_gl_Release (gl);
        vlc_object_release(surface);
    }

    CommonClean(vd);

    free(sys);
}

/* */
static picture_pool_t *Pool(vout_display_t *vd, unsigned count)
{
    vout_display_sys_t *sys = vd->sys;

    if (!sys->sys.pool && vlc_gl_MakeCurrent (sys->gl) == VLC_SUCCESS)
    {
        sys->sys.pool = vout_display_opengl_GetPool(sys->vgl, count);
        vlc_gl_ReleaseCurrent (sys->gl);
    }
    return sys->sys.pool;
}

static void Prepare(vout_display_t *vd, picture_t *picture, subpicture_t *subpicture,
                    vlc_tick_t date)
{
    Manage(vd);
    VLC_UNUSED(date);
    vout_display_sys_t *sys = vd->sys;

    if (vlc_gl_MakeCurrent (sys->gl) == VLC_SUCCESS)
    {
        vout_display_opengl_Prepare (sys->vgl, picture, subpicture);
        vlc_gl_ReleaseCurrent (sys->gl);
    }
}

static void Display(vout_display_t *vd, picture_t *picture)
{
    vout_display_sys_t *sys = vd->sys;
    VLC_UNUSED(picture);

    if (vlc_gl_MakeCurrent (sys->gl) == VLC_SUCCESS)
    {
        vout_display_opengl_Display (sys->vgl, &vd->source);
        vlc_gl_ReleaseCurrent (sys->gl);
    }

    CommonDisplay(vd);
}

static void Manage (vout_display_t *vd)
{
    vout_display_sys_t *sys = vd->sys;

    CommonManage(vd);

    const int width  = sys->sys.rect_dest.right  - sys->sys.rect_dest.left;
    const int height = sys->sys.rect_dest.bottom - sys->sys.rect_dest.top;
    vlc_gl_Resize (sys->gl, width, height);
    if (vlc_gl_MakeCurrent (sys->gl) != VLC_SUCCESS)
        return;
    vout_display_opengl_SetWindowAspectRatio(sys->vgl, (float)width / height);
    vout_display_opengl_Viewport(sys->vgl, 0, 0, width, height);
    vlc_gl_ReleaseCurrent (sys->gl);
}
