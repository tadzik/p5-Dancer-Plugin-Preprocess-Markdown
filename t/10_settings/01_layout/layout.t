use strict;
use warnings;
use Plack::Test;
use HTTP::Request::Common;
use Test::More import => ['!pass'];

plan tests => 4;

use lib 't/10_settings/01_layout/app';
use LayoutApp;
my $app = LayoutApp->to_app;
my $test = Plack::Test->create($app);

my $res = $test->request(GET '/foo.html');
like $res->content, qr/^main layout/, 'Default layout is applied';
$res = $test->request(GET '/1/foo.html');
like $res->content, qr/^layout 1/, 'Path-specific layout is applied';
$res = $test->request(GET '/2/foo.html');
like $res->content, qr/^layout 2/, 'Another path-specific layout is applied';
$res = $test->request(GET '/3/foo.html');
unlike $res->content, qr/^main layout/, 'No layout is applied';
