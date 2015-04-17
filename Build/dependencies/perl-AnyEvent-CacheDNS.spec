#
# spec file for package perl-AnyEvent-CacheDNS
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


Name:           perl-AnyEvent-CacheDNS
Version:        0.08
Release:        0
%define cpan_name AnyEvent-CacheDNS
Summary:        Simple DNS resolver with caching
License:        Artistic-1.0 or GPL-1.0+
Group:          Development/Libraries/Perl
Url:            http://search.cpan.org/dist/AnyEvent-CacheDNS/
Source:         http://www.cpan.org/authors/id/P/PO/POTYL/%{cpan_name}-%{version}.tar.gz
BuildArch:      noarch
BuildRoot:      %{_tmppath}/%{name}-%{version}-build
BuildRequires:  perl
BuildRequires:  perl-macros
BuildRequires:  perl(AnyEvent)
BuildRequires:  perl(Module::Build)
#BuildRequires: perl(AnyEvent::CacheDNS)
#BuildRequires: perl(AnyEvent::DNS)
Requires:       perl(AnyEvent)
%{perl_requires}

%description
This module provides a very simple DNS resolver that caches its results and
can improve the connection times to remote hosts.

%prep
%setup -q -n %{cpan_name}-%{version}

%build
%{__perl} Build.PL installdirs=vendor
./Build build flags=%{?_smp_mflags}

%check
./Build test

%install
./Build install destdir=%{buildroot} create_packlist=0
%perl_gen_filelist

%files -f %{name}.files
%defattr(-,root,root,755)
%doc Changes README

%changelog
