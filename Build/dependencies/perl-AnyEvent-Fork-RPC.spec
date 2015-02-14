#
# spec file for package perl-AnyEvent-Fork-RPC
#
# Copyright (c) 2015 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#


Name:           perl-AnyEvent-Fork-RPC
Version:        1.21
Release:        0
%define cpan_name AnyEvent-Fork-RPC
Summary:        AnyEvent::Fork::RPC Perl module
License:        CHECK(GPL-1.0+ or Artistic-1.0)
Group:          Development/Libraries/Perl
Url:            http://search.cpan.org/dist/AnyEvent-Fork-RPC/
#Source:        http://www.cpan.org/authors/id/M/ML/MLEHMANN/AnyEvent-Fork-RPC-%{version}.tar.gz
Source:         AnyEvent-Fork-RPC-%{version}.tar.gz
BuildArch:      noarch
BuildRoot:      %{_tmppath}/%{name}-%{version}-build
BuildRequires:  perl
BuildRequires:  perl-macros
BuildRequires:  perl-Guard
BuildRequires:  perl-IO-FDPass
BuildRequires:  perl-AnyEvent
BuildRequires:  perl-common-sense
BuildRequires:  perl-AnyEvent-Fork
BuildRequires:  perl-Proc-FastSpawn
Requires:       perl
Requires:       perl-Guard
Requires:       perl-IO-FDPass
Requires:       perl-AnyEvent
Requires:       perl-common-sense
Requires:       perl-AnyEvent-Fork
Requires:       perl-Proc-FastSpawn
%{perl_requires}

%description
AnyEvent::Fork::RPC Perl module

%prep
%setup -q -n AnyEvent-Fork-RPC-%{version}

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
%{__make} %{?_smp_mflags}

%check
%{__make} test

%install
%perl_make_install
%perl_process_packlist
%perl_gen_filelist

%files -f %{name}.files
%defattr(-,root,root,755)

%changelog
