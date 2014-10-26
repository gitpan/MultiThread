########################################
#
# Author: David Spadea
# Web: http://www.spadea.net
#
# This code is release under the same terms 
# as the PERL interpreter.
#
########################################

package MultiThread;

our $VERSION = '0.8';

package MultiThread::Base;

require 5.008;

use strict;
use warnings;

use threads;
use threads::shared;
use Thread::Queue;
use Data::Dumper;
use Sys::CPU;

use Storable qw(freeze thaw);

sub new
{

	my $class = shift;

	my $self =  {};
	
	share($$self{ProcessingCount}); 

	$$self{ProcessingCount} = 0;
	share($$self{Shutdown});
	share($$self{Responses});

	$$self{Threads} = [];

	$self = bless($self, $class);

	return $self;

}

sub shutdown
{
	my $self = shift;
	$$self{Shutdown} = 1;

	foreach my $thread (@{ $$self{Threads} } )
	{
		$thread->join if ($thread->tid);
	}

	return 1;
}

sub worker
{
	my $self = shift;
	my $workersub = shift;
	my $inputq = shift;
	my $outputq = shift;

	while(1) 
	{
		my $ticket = $inputq->dequeue_nb;
		if (! $ticket)
		{
			# Only shut down if all work has been processed (no requests).
			if ($$self{Shutdown})
			{
				return 0;
			}

			sleep 1;
		}
		else
		{

			$ticket = thaw($ticket);

			my $resp = eval { $workersub->( @{ $$ticket{Request} }) };

			my $exception = $@ if $@;

			$$ticket{Response} = $resp;
			$$ticket{Request} = [$resp]; # in case we're sending this downstream
			$$ticket{Exception} = $exception;

			$resp = freeze( $ticket );

			$outputq->enqueue( $resp );

			$exception = undef;
			$resp = undef;
		}
	}
}

sub pending_responses
{
	my $self = shift;

	return ( $$self{ProcessingCount} + $$self{Responses}->pending ) > 0 ? 1 : 0;
}

sub send_request
{
	my $self = shift;
	my @request = @_;

	$$self{TicketNumber}++; # no need to lock. Only modified in main thread.

	# OriginalRequest is set here and never modified. It should be sent back to the caller in the response queue.
	my $reqticket = { TicketNumber => $$self{TicketNumber}, Request => \@request, OriginalRequest => \@request };

	$$self{Requests}->enqueue(freeze($reqticket));
	$$self{ProcessingCount}++;

	return $$self{TicketNumber};
}

sub get_response
{
	my $self = shift;

	my %opts = @_;

	my $resp;

	if ($opts{NoWait})
	{
		$resp = thaw ( $$self{Responses}->dequeue_nb );
	}
	else
	{
		$resp = thaw ( $$self{Responses}->dequeue );
	}

	delete $$resp{Request}; # Was probably modified. Remove to eliminate confusion. 

	$$self{ProcessingCount}-- if $resp;
	return $resp;
}


package MultiThread::Pipeline;

=head1 MultiThread::Pipeline

  use MultiThread;

  my $pipeline = MultiThread::Pipeline->new( Pipeline => [ \&add_one, \&add_two ] );

  # Push 10 requests into the queue for processing.
  # Worker processing will begin immediately.
  map {  
  	$ticketnum = $pipeline->send_request( $_ );
  } ( 1..10 );

  # Gather responses back from the response queue. They may
  # not be in the original order. Use the TicketNumber or OriginalRequest
  # attributes of the ticket to identify the work unit. TicketNumber will
  # correspond to the ticket number returned by $workpool->send_request(). 
  #
  # DO NOT count on TicketNumber being an integer. It may be necessary
  # to use alphanumeric at some point to avoid numeric overflows for large 
  # workloads or long-running processes. Simply compare TicketNumbers 
  # as strings, and you'll be safe.

  while ( $pipeline->pending_responses )
  {
	# get_response has a NoWait => 1 option for non-blocking reads
	# if you'd rather write a polling loop instead.
	
  	my $ticket = $pipeline->get_response; # or get_response( NoWait => 1)
  	printf "Answer was %s\n", $$ticket{Response};
  }

  $pipeline->shutdown;

  sub add_one {
	my $input = shift;
	return $input + 1;
  }

  sub add_two {
	my $input = shift;
	return $input + 2;
  }

=cut

=head1 PURPOSE

This module implements a Pipeline multithreading model. Several concurrent
threads are started -- one for each subroutine in the pipeline. The subs
are daisy-chained together by queues. The output queue of one sub is the input
queue of the following sub. 

In the contrived example above, add_one is the initial sub in the pipeline. It takes the request
and adds one to it, returning the result. The result of add_one is fed as a request
directly into add_two, which adds two and returns the result. Because add_two is the final
sub in the chain, its output will be returned to the user via the get_response method. 

MultiThread::Pipeline is great when you have multiple steps that take different times to complete. 
MultiThread::Pipeline handles the inter-step queuing for you, so you don't need to worry about
what happens when one step outruns another. Each step simply processes asynchronously
as quickly as it can. 

One major consideration with Thread::Pipeline versus Thread::WorkerPool is that
ThreadPipeline starts one thread for every sub in the pipeline. Depending on your work load
and the nature of your processing, this may prove counterproductive. In that case, use Thread::WorkerPool
instead.

=cut


=head1 METHODS

=cut

require 5.008;

use strict;
use warnings;

use base qw( MultiThread::Base );
use Thread::Queue;
use Data::Dumper;

use Storable qw(freeze thaw);

=head2 new

Create a new MultiThread::Pipeline object.

=head3 Pipeline

This required parameter takes an arrayref of coderefs which represent the pipeline. 
A single thread will be started for each coderef, and they will be daisychained together
in the order given in the array. The first sub will consume the original request,
and the last sub in the chain will return its results to the caller.

=cut


sub new
{

	my $class = shift;
	my %opts = @_;

	unless ( $opts{Pipeline} )
	{
		print "You must supply a arrayref of coderefs using the Pipeline parameter!\n";
		return undef;
	}

	my %defaults = (
	);


	my $self = $class->SUPER::new;
	
	map {
		$opts{$_} = $defaults{$_} unless defined $opts{$_};
	} keys %defaults;

	$$self{Requests} = Thread::Queue->new();
	$$self{Pipeline} = $opts{Pipeline};

	$self = bless($self, $class);

	$self->start_pipeline($$self{Pipeline});

	return $self;

}

sub start_pipeline
{
	my $self = shift;
	my $entrypoints = shift;

	my ($inputq, $outputq);

	$inputq = $$self{Requests};

	foreach my $worker (@{$entrypoints})
	{
		$outputq = Thread::Queue->new;
		
		my $t = threads->create(\&MultiThread::Base::worker, $self, $worker, $inputq, $outputq);

		$inputq = $outputq;
		push (@{ $$self{Threads} }, $t) if ($t);
	}

	$$self{Responses} = $outputq;

	return 1;
}



package MultiThread::WorkerPool;

=head1 MultiThread::WorkerPool

  use MultiThread;

  my $workerpool = MultiThread::WorkerPool->new( EntryPoint => \&add_one );

  # Push 10 requests into the queue for processing.
  # Worker processing will begin immediately.
  map {  
  	$ticketnum = $workerpool->send_request( $_ );
  } ( 1..10 );

  # Gather responses back from the response queue. They may
  # not be in the original order. Use the TicketNumber or OriginalRequest
  # attributes of the ticket to identify the work unit. TicketNumber will
  # correspond to the ticket number returned by $workpool->send_request(). 
  #
  # DO NOT count on TicketNumber being an integer. It may be necessary
  # to use alphanumeric at some point to avoid numeric overflows for large 
  # workloads or long-running processes. Simply compare TicketNumbers 
  # as strings, and you'll be safe.

  while ( $workerpool->pending_responses )
  {
	# get_response has a NoWait => 1 option for non-blocking reads
	# if you'd rather write a polling loop instead.
	
  	my $ticket = $workerpool->get_response; # or get_response( NoWait => 1)
  	printf "Answer was %s\n", $$ticket{Response};
  }

  $workerpool->shutdown;

  sub add_one {
	my $input = shift;
	return $input + 1;
  }


=cut

=head1 PURPOSE

This module implements a WorkerPool multithreading model. Several concurrent
threads are started using a single sub for processing. All requests are serviced 
in parallel using the sub provided. 

MultiThread::WorkerPool is ideal when you have many items that must all be processed 
similarly, as quickly as possible. Simply write the sub that will handle the processing
and hand it off to Thread::WorkerPool to run several instances of your sub 
to process your work items. 

All items are put onto a single work queue, and the first available thread will
consume and process it. All threads in a Worker Pool are identical. Compare this
to a MultiThread::Pipeline, where each thread runs a different subroutine. 

=cut

=head1 METHODS

=cut


require 5.008;

use strict;
use warnings;

# This has to be before "use Thread::Queue"!
use base qw(MultiThread::Base);

use threads::shared;
use Thread::Queue;
use Data::Dumper;

=head2 new

  Thread::WorkerPool->new( %opts );

=head3 MaxWorkers

The MaxWorkers parameter overrides automatic detection of CPU count. Normally,
the WorkerPool will figure out how many CPUs are on the host machine, and will 
start an equal number of workers. If it incorrectly detects CPU count for your machine,
or if you know it's safe to start more or less, you can use this parameter 
to do so.

=head3 EntryPoint

Pass in a sub reference to the initial sub to be called in each thread. This sub will
be called for each item on the queue, and will run in parallel with itself. 

=cut

sub new
{

	my $class = shift;
	my %opts = @_;

	unless ( $opts{EntryPoint} )
	{
		print "You must supply a coderef using the EntryPoint parameter!\n";
		return undef;
	}

	my %defaults = (
		  MaxWorkers => &get_CPU_count()
	);


	map {
		$opts{$_} = $defaults{$_} unless defined $opts{$_};
	} keys %defaults;

	my $self = $class->SUPER::new;

	$$self{EntryPoint} = $opts{EntryPoint};
	$$self{MaxWorkers} = $opts{MaxWorkers};

	$self = bless($self, $class);

	$self->start_pool;

	return $self;

}

# I think this can be combined with MultiThread::Pipeline::start_pipeline and moved to MultiThread::Base. 
# They're very similar.
sub start_pool
{
	my $self = shift;

	my $class = ref($self);

	my $inputq = Thread::Queue->new;
	my $outputq = Thread::Queue->new;
	my $entrypoint = $$self{EntryPoint};

	$$self{Requests} = $inputq;
	$$self{Responses} = $outputq;

	share($inputq);

	for (my $x = 0; $x < $$self{MaxWorkers}; $x++)
	{
		my $t = threads->create(\&MultiThread::Base::worker, $self, $entrypoint, $inputq, $outputq);

		push (@{ $$self{Threads} }, $t) if ($t);
	}

	return 1;
}

sub get_CPU_count
{
	my $procs = Sys::CPU::cpu_count();
	return $procs ? $procs : 1; # In case cpu_count returns 0 or undef
}

=head1 COMMON INSTANCE METHODS

Both MultiThread::WorkerPool and MultiThread::Pipeline derive from MultiThread::Base,
so they share a number of methods. 

=head2 pending_responses

Returns a boolean signifying whether there are still outstanding requests to be
processed. This will return true until the last response has been collected.

This method has no 

=head2 send_request 

This enqueues a request for processing. It takes no arguments of its own; all arguments 
given will be passed directly to the subs you provide as @_. Call this exactly as you 
would call your worker/pipeline methods directly. Just remember that any arguments 
given must be serializable by the Storable module.

This sub returns a unique ticket number (unique within the scope of the current instance). 
This ticket number will be present in the response as well, so you can match up the 
request with the response ticket if you need to.

=head2 get_response

When worker subs finish their work, their return values are put back onto a response queue
for collection. Call this method on your WorkerPool or Pipeline object to retrieve the
return tickets, one at a time. 

The value returned is not only the return value of the worker thread. It is a hash containing
TicketNumber, OriginalRequest, Response, and Exception. 

=head3 Exception

If the Pipeline or WorkerPool die()'s, this will be set to the die() message. This is so that
a single request's problem does not prevent other requests from running to completion. 

I do not provide a facility for allowing one request to kill the whole program because there's 
no way of knowing the state of each request at the time the program died. If you really want 
that behavior, do something like this in your get_response loop:

  die($$ticket{Exception}) if ($$ticket{Exception});


=head3 OriginalRequest

The original request as given to send_request. This is necessary because the Request
is set to the return value of each sub for use in Pipelining. 

=head3 Response 

The return value of the final sub in a Pipeline or the Worker in a WorkerPool. 

=head3 TicketNumber

The request number assigned to the request and returned to the caller of send_request. This
number persists throughout the process for the purpose of matching up the response with the
request. 


=head1 BUGS

Be careful that you're passing serializable data types that can be freeze()'d and thaw()'d. 
These modules make extensive use of Thread::Queue, which requires all structures
be serialized before being passed onto the queues.

MultiThread::Pipeline needs a built-in way to allow each step to have its own WorkerPool.
(Thanks for the idea, Aaron!) 


=head1 AUTHOR

David Spadea
http://www.spadea.net

=cut

=head1 COPYRIGHT & LICENSE

Copyright 2008 David Spadea, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1;

