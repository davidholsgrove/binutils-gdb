# This shell script emits a C file. -*- C -*-
#   Copyright (C) 2013, 2014 Free Software Foundation, Inc.
#
# This file is part of GNU Binutils.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street - Fifth Floor, Boston,
# MA 02110-1301, USA.
#

# This file is sourced from elf32.em, and defines extra Nios II ELF
# specific routines. Taken from metagelf.em.
#
fragment <<EOF

#include "ldctor.h"
#include "elf32-nios2.h"


/* Fake input file for stubs.  */
static lang_input_statement_type *stub_file;

/* Whether we need to call nios2_layout_sections_again.  */
static int need_laying_out = 0;


/* This is called before the input files are opened.  We create a new
   fake input file to hold the stub sections.  */

static void
nios2elf_create_output_section_statements (void)
{
  extern const bfd_target bfd_elf32_littlenios2_vec, bfd_elf32_bignios2_vec;

  if (link_info.output_bfd->xvec != &bfd_elf32_littlenios2_vec
      && link_info.output_bfd->xvec != &bfd_elf32_bignios2_vec)
    return;

  /* If --no-relax was not explicitly specified by the user, enable
     relaxation.  If it's not enabled (either explicitly or by default),
     we're done, as we won't need to create any stubs.  */
  if (!link_info.relocatable && RELAXATION_DISABLED_BY_DEFAULT)
    ENABLE_RELAXATION;
  if (!RELAXATION_ENABLED)
    return;

  stub_file = lang_add_input_file ("linker stubs",
				   lang_input_file_is_fake_enum,
				   NULL);
  stub_file->the_bfd = bfd_create ("linker stubs", link_info.output_bfd);
  if (stub_file->the_bfd == NULL
      || ! bfd_set_arch_mach (stub_file->the_bfd,
			      bfd_get_arch (link_info.output_bfd),
			      bfd_get_mach (link_info.output_bfd)))
    {
      einfo ("%X%P: can not create BFD %E\n");
      return;
    }

  stub_file->the_bfd->flags |= BFD_LINKER_CREATED;
  ldlang_add_file (stub_file);
}


struct hook_stub_info
{
  lang_statement_list_type add;
  asection *input_section;
};

/* Traverse the linker tree to find the spot where the stub goes.  */

static bfd_boolean
hook_in_stub (struct hook_stub_info *info, lang_statement_union_type **lp,
	      bfd_boolean afterp)
{
  lang_statement_union_type *l;
  bfd_boolean ret;

  for (; (l = *lp) != NULL; lp = &l->header.next)
    {
      switch (l->header.type)
	{
	case lang_constructors_statement_enum:
	  ret = hook_in_stub (info, &constructor_list.head, afterp);
	  if (ret)
	    return ret;
	  break;

	case lang_output_section_statement_enum:
	  ret = hook_in_stub (info,
			      &l->output_section_statement.children.head,
			      afterp);
	  if (ret)
	    return ret;
	  break;

	case lang_wild_statement_enum:
	  ret = hook_in_stub (info, &l->wild_statement.children.head, afterp);
	  if (ret)
	    return ret;
	  break;

	case lang_group_statement_enum:
	  ret = hook_in_stub (info, &l->group_statement.children.head, afterp);
	  if (ret)
	    return ret;
	  break;

	case lang_input_section_enum:
	  if (l->input_section.section == info->input_section)
	    {
	      /* We've found our section.  Insert the stub immediately
		 before or after its associated input section.  */
	      if (afterp)
		{
		  *(info->add.tail) = l->header.next;
		  l->header.next = info->add.head;
		}
	      else
		{
		  *lp = info->add.head;
		  *(info->add.tail) = l;
		}
	      return TRUE;
	    }
	  break;

	case lang_data_statement_enum:
	case lang_reloc_statement_enum:
	case lang_object_symbols_statement_enum:
	case lang_output_statement_enum:
	case lang_target_statement_enum:
	case lang_input_statement_enum:
	case lang_assignment_statement_enum:
	case lang_padding_statement_enum:
	case lang_address_statement_enum:
	case lang_fill_statement_enum:
	  break;

	default:
	  FAIL ();
	  break;
	}
    }
  return FALSE;
}

/* Call-back for elf32_nios2_size_stubs.  */

/* Create a new stub section, and arrange for it to be linked
   immediately before or after INPUT_SECTION, according to AFTERP.  */

static asection *
nios2elf_add_stub_section (const char *stub_sec_name, asection *input_section,
			   bfd_boolean afterp)
{
  asection *stub_sec;
  flagword flags;
  asection *output_section;
  const char *secname;
  lang_output_section_statement_type *os;
  struct hook_stub_info info;

  flags = (SEC_ALLOC | SEC_LOAD | SEC_READONLY | SEC_CODE
	   | SEC_HAS_CONTENTS | SEC_RELOC | SEC_IN_MEMORY | SEC_KEEP);
  stub_sec = bfd_make_section_anyway_with_flags (stub_file->the_bfd,
						 stub_sec_name, flags);
  if (stub_sec == NULL)
    goto err_ret;

  output_section = input_section->output_section;
  secname = bfd_get_section_name (output_section->owner, output_section);
  os = lang_output_section_find (secname);

  info.input_section = input_section;
  lang_list_init (&info.add);
  lang_add_section (&info.add, stub_sec, NULL, os);

  if (info.add.head == NULL)
    goto err_ret;

  if (hook_in_stub (&info, &os->children.head, afterp))
    return stub_sec;

 err_ret:
  einfo ("%X%P: can not make stub section: %E\n");
  return NULL;
}


/* Another call-back for elf32_nios2_size_stubs.  */

static void
nios2elf_layout_sections_again (void)
{
  /* If we have changed sizes of the stub sections, then we need
     to recalculate all the section offsets.  This may mean we need to
     add even more stubs.  */
  gld${EMULATION_NAME}_map_segments (TRUE);
  need_laying_out = -1;
}


static void
build_section_lists (lang_statement_union_type *statement)
{
  if (statement->header.type == lang_input_section_enum)
    {
      asection *i = statement->input_section.section;

      if (i->sec_info_type != SEC_INFO_TYPE_JUST_SYMS
	  && (i->flags & SEC_EXCLUDE) == 0
	  && i->output_section != NULL
	  && i->output_section->owner == link_info.output_bfd)
	{
	  nios2_elf32_next_input_section (&link_info, i);
	}
    }
}


/* For Nios II we use this opportunity to build linker stubs.  */

static void
gld${EMULATION_NAME}_after_allocation (void)
{
  /* bfd_elf_discard_info just plays with data and debugging sections,
     ie. doesn't affect code size, so we can delay resizing the
     sections.  It's likely we'll resize everything in the process of
     adding stubs.  */
  if (bfd_elf_discard_info (link_info.output_bfd, &link_info))
    need_laying_out = 1;

  /* If generating a relocatable output file, then we don't
     have to examine the relocs.  */
  if (stub_file != NULL && !link_info.relocatable && RELAXATION_ENABLED)
    {
      int ret = nios2_elf32_setup_section_lists (link_info.output_bfd,
						 &link_info);

      if (ret != 0)
	{
	  if (ret < 0)
	    {
	      einfo ("%X%P: can not size stub section: %E\n");
	      return;
	    }

	  lang_for_each_statement (build_section_lists);

	  /* Call into the BFD backend to do the real work.  */
	  if (! nios2_elf32_size_stubs (link_info.output_bfd,
					stub_file->the_bfd,
					&link_info,
					&nios2elf_add_stub_section,
					&nios2elf_layout_sections_again))
	    {
	      einfo ("%X%P: can not size stub section: %E\n");
	      return;
	    }
	}
    }

  if (need_laying_out != -1)
    gld${EMULATION_NAME}_map_segments (need_laying_out);

  if (!link_info.relocatable && RELAXATION_ENABLED)
    {
      /* Now build the linker stubs.  */
      if (stub_file != NULL && stub_file->the_bfd->sections != NULL)
	{
	  if (! nios2_elf32_build_stubs (&link_info))
	    einfo ("%X%P: can not build stubs: %E\n");
	}
    }
}


/* Avoid processing the fake stub_file in vercheck, stat_needed and
   check_needed routines.  */

static void (*real_func) (lang_input_statement_type *);

static void nios2_for_each_input_file_wrapper (lang_input_statement_type *l)
{
  if (l != stub_file)
    (*real_func) (l);
}

static void
nios2_lang_for_each_input_file (void (*func) (lang_input_statement_type *))
{
  real_func = func;
  lang_for_each_input_file (&nios2_for_each_input_file_wrapper);
}

#define lang_for_each_input_file nios2_lang_for_each_input_file

EOF


# Put these extra nios2elf routines in ld_${EMULATION_NAME}_emulation
#
LDEMUL_AFTER_ALLOCATION=gld${EMULATION_NAME}_after_allocation
LDEMUL_CREATE_OUTPUT_SECTION_STATEMENTS=nios2elf_create_output_section_statements
