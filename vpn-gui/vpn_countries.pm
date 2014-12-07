package vpn_countries;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#         Kimmo R. M. Hovi <kimmo@fairwarning.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#


use strict;
use warnings;


sub import{
	no strict 'refs';
	foreach (@_) {
		*{"vpn_window::$_"}=\&$_;
	}
}


use constant {
	OPENVPN_DIR	=> "/etc/openvpn/",
	DEBUG		=> 1
};


sub get_country_codes {
	my %country_codes = (
		'ad'	=> 'Andorra',
		'ae'	=> 'United Arab Emirates',
		'af'	=> 'Afghanistan',
		'ag'	=> 'Antigua and Barbuda',
		'ai'	=> 'Anguilla',
		'al'	=> 'Albania',
		'am'	=> 'Armenia',
		'ao'	=> 'Angola',
		'aq'	=> 'Antarctica',
		'ar'	=> 'Argentina',
		'as'	=> 'American Samoa',
		'at'	=> 'Austria',
		'au'	=> 'Australia',
		'aw'	=> 'Aruba',
		'ax'	=> 'Åland Islands',
		'az'	=> 'Azerbaijan',
		'ba'	=> 'Bosnia and Herzegovina',
		'bb'	=> 'Barbados',
		'bd'	=> 'Bangladesh',
		'be'	=> 'Belgium',
		'bf'	=> 'Burkina Faso',
		'bg'	=> 'Bulgaria',
		'bh'	=> 'Bahrain',
		'bi'	=> 'Burundi',
		'bj'	=> 'Benin',
		'bl'	=> 'Saint Barthélemy',
		'bm'	=> 'Bermuda',
		'bn'	=> 'Brunei Darussalam',
		'bo'	=> 'Bolivia, Plurinational State of',
		'bq'	=> 'Bonaire, Sint Eustatius and Saba',
		'br'	=> 'Brazil',
		'bs'	=> 'Bahamas',
		'bt'	=> 'Bhutan',
		'bv'	=> 'Bouvet Island',
		'bw'	=> 'Botswana',
		'by'	=> 'Belarus',
		'bz'	=> 'Belize',
		'ca'	=> 'Canada',
		'cc'	=> 'Cocos (Keeling) Islands',
		'cd'	=> 'Congo, the Democratic Republic of the',
		'cf'	=> 'Central African Republic',
		'cg'	=> 'Congo',
		'ch'	=> 'Switzerland',
		'ci'	=> 'Côte d\'Ivoire',
		'ck'	=> 'Cook Islands',
		'cl'	=> 'Chile',
		'cm'	=> 'Cameroon',
		'ch'	=> 'China',
		'co'	=> 'Colombia',
		'cr'	=> 'Costa Rica',
		'cu'	=> 'Cuba',
		'cv'	=> 'Cape Verde',
		'cw'	=> 'Curaçao',
		'cx'	=> 'Christmas Island',
		'cy'	=> 'Cyprus',
		'cz'	=> 'Czech Republic',
		'de'	=> 'Germany',
		'dj'	=> 'Djibouti',
		'dk'	=> 'Denmark',
		'dm'	=> 'Dominica',
		'do'	=> 'Dominican Republic',
		'dz'	=> 'Algeria',
		'ec'	=> 'Ecuador',
		'ee'	=> 'Estonia',
		'eg'	=> 'Egypt',
		'eh'	=> 'Western Sahara',
		'er'	=> 'Eritrea',
		'es'	=> 'Spain',
		'et'	=> 'Ethiopia',
		'fi'	=> 'Finland',
		'fj'	=> 'Fiji',
		'fk'	=> 'Falkland Islands (Malvinas)',
		'fm'	=> 'Micronesia, Federated States of',
		'fo'	=> 'Faroe Islands',
		'fr'	=> 'France',
		'ga'	=> 'Gabon',
		'uk'	=> 'United Kingdom',
		'gd'	=> 'Grenada',
		'ge'	=> 'Georgia',
		'gf'	=> 'French Guiana',
		'gg'	=> 'Guernsey',
		'gh'	=> 'Ghana',
		'gi'	=> 'Gibraltar',
		'gl'	=> 'Greenland',
		'gm'	=> 'Gambia',
		'gn'	=> 'Guinea',
		'gp'	=> 'Guadeloupe',
		'gq'	=> 'Equatorial Guinea',
		'gr'	=> 'Greece',
		'gs'	=> 'South Georgia and the South Sandwich Islands',
		'gt'	=> 'Guatemala',
		'gu'	=> 'Guam',
		'gw'	=> 'Guinea-Bissau',
		'gy'	=> 'Guyana',
		'hk'	=> 'Hong Kong',
		'hm'	=> 'Heard Island and McDonald Islands',
		'hn'	=> 'Honduras',
		'hr'	=> 'Croatia',
		'ht'	=> 'Haiti',
		'hu'	=> 'Hungary',
		'id'	=> 'Indonesia',
		'ie'	=> 'Ireland',
		'il'	=> 'Israel',
		'im'	=> 'Isle of Man',
		'in'	=> 'India',
		'io'	=> 'British Indian Ocean Territory',
		'iq'	=> 'Iraq',
		'ir'	=> 'Iran, Islamic Republic of',
		'is'	=> 'Iceland',
		'it'	=> 'Italy',
		'je'	=> 'Jersey',
		'jm'	=> 'Jamaica',
		'jo'	=> 'Jordan',
		'jp'	=> 'Japan',
		'ke'	=> 'Kenya',
		'kg'	=> 'Kyrgyzstan',
		'kh'	=> 'Cambodia',
		'ki'	=> 'Kiribati',
		'km'	=> 'Comoros',
		'kn'	=> 'Saint Kitts and Nevis',
		'kp'	=> 'Korea, Democratic People\'s Republic of',
		'kr'	=> 'Korea, Republic of',
		'kw'	=> 'Kuwait',
		'ky'	=> 'Cayman Islands',
		'kz'	=> 'Kazakhstan',
		'la'	=> 'Lao People\'s Democratic Republic',
		'lb'	=> 'Lebanon',
		'lc'	=> 'Saint Lucia',
		'li'	=> 'Liechtenstein',
		'lk'	=> 'Sri Lanka',
		'lr'	=> 'Liberia',
		'ls'	=> 'Lesotho',
		'lt'	=> 'Lithuania',
		'lu'	=> 'Luxembourg',
		'lv'	=> 'Latvia',
		'ly'	=> 'Libyan Arab Jamahiriya',
		'ma'	=> 'Morocco',
		'mc'	=> 'Monaco',
		'md'	=> 'Moldova, Republic of',
		'me'	=> 'Montenegro',
		'mf'	=> 'Saint Martin (French part)',
		'mg'	=> 'Madagascar',
		'mh'	=> 'Marshall Islands',
		'mk'	=> 'Macedonia, the former Yugoslav Republic of',
		'ml'	=> 'Mali',
		'mm'	=> 'Myanmar',
		'mn'	=> 'Mongolia',
		'mo'	=> 'Macao',
		'mp'	=> 'Northern Mariana Islands',
		'mq'	=> 'Martinique',
		'mr'	=> 'Mauritania',
		'ms'	=> 'Montserrat',
		'mt'	=> 'Malta',
		'mu'	=> 'Mauritius',
		'mv'	=> 'Maldives',
		'mw'	=> 'Malawi',
		'mx'	=> 'Mexico',
		'my'	=> 'Malaysia',
		'mz'	=> 'Mozambique',
		'na'	=> 'Namibia',
		'nc'	=> 'New Caledonia',
		'ne'	=> 'Niger',
		'nf'	=> 'Norfolk Island',
		'ng'	=> 'Nigeria',
		'ni'	=> 'Nicaragua',
		'nl'	=> 'Netherlands',
		'no'	=> 'Norway',
		'np'	=> 'Nepal',
		'nr'	=> 'Nauru',
		'nu'	=> 'Niue',
		'nz'	=> 'New Zealand',
		'om'	=> 'Oman',
		'pa'	=> 'Panama',
		'pe'	=> 'Peru',
		'pf'	=> 'French Polynesia',
		'pg'	=> 'Papua New Guinea',
		'ph'	=> 'Philippines',
		'pk'	=> 'Pakistan',
		'pl'	=> 'Poland',
		'pm'	=> 'Saint Pierre and Miquelon',
		'pn'	=> 'Pitcairn',
		'pr'	=> 'Puerto Rico',
		'ps'	=> 'Palestinian Territory, Occupied',
		'pt'	=> 'Portugal',
		'pw'	=> 'Palau',
		'py'	=> 'Paraguay',
		'qa'	=> 'Qatar',
		're'	=> 'Réunion',
		'ro'	=> 'Romania',
		'rs'	=> 'Serbia',
		'ru'	=> 'Russian Federation',
		'rw'	=> 'Rwanda',
		'sa'	=> 'Saudi Arabia',
		'sb'	=> 'Solomon Islands',
		'sc'	=> 'Seychelles',
		'sd'	=> 'Sudan',
		'se'	=> 'Sweden',
		'sg'	=> 'Singapore',
		'sh'	=> 'Saint Helena, Ascension and Tristan da Cunha',
		'si'	=> 'Slovenia',
		'sj'	=> 'Svalbard and Jan Mayen',
		'sk'	=> 'Slovakia',
		'sl'	=> 'Sierra Leone',
		'sm'	=> 'San Marino',
		'sn'	=> 'Senegal',
		'so'	=> 'Somalia',
		'sr'	=> 'Suriname',
		'st'	=> 'Sao Tome and Principe',
		'sv'	=> 'El Salvador',
		'sx'	=> 'Sint Maarten (Dutch part)',
		'sy'	=> 'Syrian Arab Republic',
		'sz'	=> 'Swaziland',
		'tc'	=> 'Turks and Caicos Islands',
		'td'	=> 'Chad',
		'tf'	=> 'French Southern Territories',
		'tg'	=> 'Togo',
		'th'	=> 'Thailand',
		'tj'	=> 'Tajikistan',
		'tk'	=> 'Tokelau',
		'tl'	=> 'Timor-Leste',
		'tm'	=> 'Turkmenistan',
		'tn'	=> 'Tunisia',
		'to'	=> 'Tonga',
		'tr'	=> 'Turkey',
		'tt'	=> 'Trinidad and Tobago',
		'tv'	=> 'Tuvalu',
		'tw'	=> 'Taiwan, Province of China',
		'tz'	=> 'Tanzania, United Republic of',
		'ua'	=> 'Ukraine',
		'ug'	=> 'Uganda',
		'um'	=> 'United States Minor Outlying Islands',
		'us'	=> 'United States',
		'uy'	=> 'Uruguay',
		'uz'	=> 'Uzbekistan',
		'va'	=> 'Holy See (Vatican City State)',
		'vc'	=> 'Saint Vincent and the Grenadines',
		've'	=> 'Venezuela, Bolivarian Republic of',
		'vg'	=> 'Virgin Islands, British',
		'vi'	=> 'Virgin Islands, U.S.',
		'vn'	=> 'Viet Nam',
		'vu'	=> 'Vanuatu',
		'wf'	=> 'Wallis and Futuna',
		'ws'	=> 'Samoa',
		'ye'	=> 'Yemen',
		'yt'	=> 'Mayotte',
		'za'	=> 'South Africa',
		'zm'	=> 'Zambia',
		'zw'	=> 'Zimbabwe'
	);
	
	return wantarray ? %country_codes : \%country_codes;
}


sub get_country_list {
	my $vpnlist  = ();
	my $duallist = ();
	my $torlist  = ();

	my $dir;
	my @tmplist;
	my $file;
	my $type;
	my $country;
	my $start;
	my $proto;

	if (opendir $dir, OPENVPN_DIR) {
		my @tmplist = readdir $dir;
		closedir $dir;
		
		foreach my $file (@tmplist) {
			next unless ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]?|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)\.ovpn/i);
			($type, $country, $proto) = ($1, $2, $4);
			if ($type eq 'vpn' ) {
				$vpnlist->{$country} = 1;
			} elsif ($type eq 'tor') {
				$torlist->{$country} = 1;
			} else { 		# $type eq 'double-'
				$duallist->{$country} = 1;
			}
		}
	}
	print "Returning " . scalar(keys %$vpnlist) . " VPN configs, " . scalar(keys %$torlist) . " TOR configs, and " . scalar(keys %$duallist) . " tunneled VPN configs\n" if DEBUG > 1;
	return wantarray ? ($vpnlist, $duallist, $torlist) : $vpnlist;
}

1;
