#!/usr/bin/env python2.7
# yahmm.py: Yet Another Hidden Markov Model library
# Contact: Jacob Schreiber ( jmschreiber91@gmail.com )
#          Adam Novak ( anovak1@ucsc.edu )

"""
For detailed documentation and examples, see the README.
"""

cimport cython
from cython.view cimport array as cvarray
from libc.math cimport log as clog, sqrt as csqrt, exp as cexp
import math, random, itertools as it, sys, bisect
import networkx
import scipy.stats, scipy.sparse, scipy.special

import numpy
cimport numpy
from matplotlib import pyplot

# Define some useful constants
DEF NEGINF = float("-inf")
DEF INF = float("inf")
DEF SQRT_2_PI = 2.50662827463

# Useful speed optimized functions
cdef inline double _log ( double x ):
	return clog( x ) if x > 0 else NEGINF

cdef inline int pair_int_max( int x, int y ):
	return x if x > y else y

cdef inline double pair_lse( double x, double y ):
	if x == INF or y == INF:
		return INF
	if x == NEGINF:
		return y
	if y == NEGINF:
		return x
	if x > y:
		return x + clog( cexp( y-x ) + 1 )
	return y + clog( cexp( x-y ) + 1 )

# Useful python-based array-intended operations
def log(value):
	"""
	Return the natural log of the given value, or - infinity if the value is 0.
	Can handle both scalar floats and numpy arrays.
	"""

	if isinstance( value, numpy.ndarray ):
		to_return = numpy.zeros(( value.shape ))
		to_return[ value > 0 ] = numpy.log( value[ value > 0 ] )
		to_return[ value == 0 ] = NEGINF
		return to_return
	return _log( value )
		
def exp(value):
	"""
	Return e^value, or 0 if the value is - infinity.
	"""
	
	return numpy.exp(value)

cdef class Distribution(object):
	"""
	Represents a probability distribution over whatever the HMM you're making is
	supposed to emit. Ought to be subclassed and have log_probability(), 
	sample(), and from_sample() overridden. Distribution.name should be 
	overridden and replaced with a unique name for the distribution type. The 
	distribution should be registered by calling register() on the derived 
	class, so that Distribution.read() can read it. Any distribution parameters 
	need to be floats stored in self.parameters, so they will be properly 
	written by write().
	"""
	
	# Instance stuff
	
	"""
	This is the name that should be used for serializing this distribution. May
	not contain newlines or spaces.
	"""

	cdef public str name
	cdef public list parameters
	cdef public numpy.ndarray points
	cdef public numpy.ndarray weights

	def __init__(self):
		"""
		Make a new Distribution with the given parameters. All parameters must 
		be floats.
		
		Storing parameters in self.parameters instead of e.g. self.mean on the 
		one hand makes distribution code ugly, because we don't get to call them
		self.mean. On the other hand, it means we don't have to override the 
		serialization code for every derived class.
		"""

		self.name = "Distribution"
		self.parameters = []
		self.distributions = {}
		
	def copy( self ):
		"""
		Return a copy of this distribution, untied. 
		"""

		return self.__class__( *self.parameters ) 

	def log_probability(self, symbol):
		"""
		Return the log probability of the given symbol under this distribution.
		"""
		
		raise NotImplementedError

	def sample(self):
		"""
		Return a random item sampled from this distribution.
		"""
		
		raise NotImplementedError
		
	def from_sample(self, items, weights=None):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		"""
		
		raise NotImplementedError
		
	def __str__(self):
		"""
		Represent this distribution in a human-readable form.
		"""
		
		return "{}({})".format(self.name, ", ".join(map(str, self.parameters)))

cdef class UniformDistribution(Distribution):
	"""
	A uniform distribution between two values.
	"""

	def __init__(self, start, end):
		"""
		Make a new Uniform distribution over floats between start and end, 
		inclusive. Start and end must not be equal.
		"""
		
		# Store the parameters
		self.parameters = [start, end]
		self.name = "UniformDistribution"
		
	def log_probability(self, symbol):
		"""
		What's the probability of the given float under this distribution?
		"""
		
		return self._log_probability( self.parameters[0], self.parameters[1], symbol )

	cdef double _log_probability( self, double a, double b, double symbol ):
		if symbol == a and symbol == b:
			return 0
		if symbol >= a and symbol <= b:
			return _log( 1.0 / ( b - a ) )
		return NEGINF
			
	def sample(self):
		"""
		Sample from this uniform distribution and return the value sampled.
		"""
		
		return random.uniform(self.parameters[0], self.parameters[1])
		
	def from_sample(self, items, weights=None):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		"""
		
		if weights is not None:
			# Throw out items with weight 0
			items = [item for (item, weight) in it.izip(items, weights) 
				if weight > 0]
		
		if len(items) == 0:
			# No sample, so just ignore it and keep our old parameters.
			return
		
		# The ML uniform distribution is just min to max.
		# Weights don't matter for this
		self.parameters[0] = numpy.min(items)
		self.parameters[1] = numpy.max(items)

cdef class NormalDistribution(Distribution):
	"""
	A normal distribution based on a mean and standard deviation.
	"""

	def __init__(self, mean, std):
		"""
		Make a new Normal distribution with the given mean mean and standard 
		deviation std.
		"""
		
		# Store the parameters
		self.parameters = [mean, std]
		self.name = "NormalDistribution"

	def log_probability(self, symbol, epsilon=1E-4):
		"""
		What's the probability of the given float under this distribution?
		
		For distributions with 0 std, epsilon is the distance within which to 
		consider things equal to the mean.
		"""

		return self._log_probability( symbol, epsilon )

	cdef double _log_probability( self, double symbol, double epsilon ):
		"""
		Do the actual math here.
		"""

		cdef double mu = self.parameters[0], theta = self.parameters[1]
		if theta == 0.0:
			if abs( symbol - mu ) < epsilon:
				return 0
			else:
				return NEGINF
  
		return _log( 1.0 / ( theta * SQRT_2_PI ) ) - ((symbol - mu) ** 2) /\
			(2 * theta ** 2)
			
	def sample(self):
		"""
		Sample from this normal distribution and return the value sampled.
		"""
		
		# This uses the same parameterization
		return random.normalvariate(*self.parameters)
		
	def from_sample(self, items, weights=None, min_std=0.01):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		
		min_std specifieds a lower limit on the learned standard deviation.
		"""
		
		if len(items) == 0:
			# No sample, so just ignore it and keep our old parameters.
			return

		# Make it be a numpy array
		items = numpy.asarray(items)
		
		if weights is None:
			# Weight everything 1 if no weights specified
			weights = numpy.ones_like(items)
		else:
			# Force whatever we have to be a Numpy array
			weights = numpy.asarray(weights)
		
		if weights.sum() == 0:
			# Since negative weights are banned, we must have no data.
			# Don't change the parameters at all.
			return
		# The ML uniform distribution is just sample mean and sample std.
		# But we have to weight them. average does weighted mean for us, but 
		# weighted std requires a trick from Stack Overflow.
		# http://stackoverflow.com/a/2415343/402891
		# Take the mean
		mean = numpy.average(items, weights=weights)

		if len(weights[weights != 0]) > 1:
			# We want to do the std too, but only if more than one thing has a 
			# nonzero weight
			# First find the variance
			variance = (numpy.dot(items ** 2 - mean ** 2, weights) / 
				weights.sum())
				
			if variance >= 0:
				std = csqrt(variance)
			else:
				# May have a small negative variance on accident. Ignore and set
				# to 0.
				std = 0
		else:
			# Only one data point, can't update std
			std = self.parameters[1]    
		
		# Enforce min std
		std = max( numpy.array([std, min_std]) )
		# Set the parameters
		self.parameters = [mean, std]

cdef class ExponentialDistribution(Distribution):
	"""
	Represents an exponential distribution on non-negative floats.
	"""
	
	def __init__(self, rate):
		"""
		Make a new inverse gamma distribution. The parameter is called "rate" 
		because lambda is taken.
		"""

		self.parameters = [rate]
		self.name = "ExponentialDistribution"
		
	def log_probability(self, symbol):
		"""
		What's the probability of the given float under this distribution?
		"""
		
		return _log(self.parameters[0]) - self.parameters[0] * symbol
		
	def sample(self):
		"""
		Sample from this exponential distribution and return the value
		sampled.
		"""
		
		return random.expovariate(*self.parameters)
		
	def from_sample(self, items, weights=None):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		"""
		
		if len(items) == 0:
			# No sample, so just ignore it and keep our old parameters.
			return
		
		# Make it be a numpy array
		items = numpy.asarray(items)
		
		if weights is None:
			# Weight everything 1 if no weights specified
			weights = numpy.ones_like(items)
		else:
			# Force whatever we have to be a Numpy array
			weights = numpy.asarray(weights)
		
		if weights.sum() == 0:
			# Since negative weights are banned, we must have no data.
			# Don't change the parameters at all.
			return
		
		# Parameter MLE = 1/sample mean, easy to weight
		# Compute the weighted mean
		weighted_mean = numpy.average(items, weights=weights)
		
		# Update parameters
		self.parameters[0] = 1.0 / weighted_mean

cdef class GammaDistribution(Distribution):
	"""
	This distribution represents a gamma distribution, parameterized in the 
	alpha/beta (shape/rate) parameterization. ML estimation for a gamma 
	distribution, taking into account weights on the data, is nontrivial, and I 
	was unable to find a good theoretical source for how to do it, so I have 
	cobbled together a solution here from less-reputable sources.
	"""
	
	def __init__(self, alpha, beta):
		"""
		Make a new gamma distribution. Alpha is the shape parameter and beta is 
		the rate parameter.
		"""
		
		self.parameters = [alpha, beta]
		self.name = "GammaDistribution"
		
	def log_probability(self, symbol):
		"""
		What's the probability of the given float under this distribution?
		"""
		
		# Gamma pdf from Wikipedia (and stats class)
		return (_log(self.parameters[1]) * self.parameters[0] - 
			math.lgamma(self.parameters[0]) + 
			_log(symbol) * (self.parameters[0] - 1) - 
			self.parameters[1] * symbol)
		
	def sample(self):
		"""
		Sample from this gamma distribution and return the value sampled.
		"""
		
		# We have a handy sample from gamma function. Unfortunately, while we 
		# use the alpha, beta parameterization, and this function uses the 
		# alpha, beta parameterization, our alpha/beta are shape/rate, while its
		# alpha/beta are shape/scale. So we have to mess with the parameters.
		return random.gammavariate(self.parameters[0], 1.0 / self.parameters[1])
		
	def from_sample(self, items, weights=None, epsilon=1E-9, 
		iteration_limit = 1000):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		
		In the Gamma case, likelihood maximization is necesarily numerical, and 
		the extension to weighted values is not trivially obvious. The algorithm
		used here includes a Newton-Raphson step for shape parameter estimation,
		and analytical calculation of the rate parameter. The extension to 
		weights is constructed using vital information found way down at the 
		bottom of an Experts Exchange page.
		
		Newton-Raphson continues until the change in the parameter is less than 
		epsilon, or until iteration_limit is reached
		
		See:
		http://en.wikipedia.org/wiki/Gamma_distribution
		http://www.experts-exchange.com/Other/Math_Science/Q_23943764.html
		"""
		
		if len(items) == 0:
			# No sample, so just ignore it and keep our old parameters.
			return

		# Make it be a numpy array
		items = numpy.asarray(items)
		
		if weights is None:
			# Weight everything 1 if no weights specified
			weights = numpy.ones_like(items)
		else:
			# Force whatever we have to be a Numpy array
			weights = numpy.asarray(weights)

		if weights.sum() == 0:
			# Since negative weights are banned, we must have no data.
			# Don't change the parameters at all.
			return

		# First, do Newton-Raphson for shape parameter.
		
		# Calculate the sufficient statistic s, which is the log of the average 
		# minus the average log. When computing the average log, we weight 
		# outside the log function. (In retrospect, this is actually pretty 
		# obvious.)
		statistic = (log(numpy.average(items, weights=weights)) - 
			numpy.average(log(items), weights=weights))

		# Start our Newton-Raphson at what Wikipedia claims a 1969 paper claims 
		# is a good approximation.
		# Really, start with new_shape set, and shape set to be far away from it
		shape = float("inf")
		
		if statistic != 0:
			# Not going to have a divide by 0 problem here, so use the good
			# estimate
			new_shape =  (3 - statistic + math.sqrt((statistic - 3) ** 2 + 24 * 
				statistic)) / (12 * statistic)
		if statistic == 0 or new_shape <= 0:
			# Try the current shape parameter
			new_shape = self.parameters[0]

		# Count the iterations we take
		iteration = 0
			
		# Now do the update loop.
		# We need the digamma (gamma derivative over gamma) and trigamma 
		# (digamma derivative) functions. Luckily, scipy.special.polygamma(0, x)
		# is the digamma function (0th derivative of the digamma), and 
		# scipy.special.polygamma(1, x) is the trigamma function.
		while abs(shape - new_shape) > epsilon and iteration < iteration_limit:
			shape = new_shape
			
			new_shape = shape - (log(shape) - 
				scipy.special.polygamma(0, shape) -
				statistic) / (1.0 / shape - scipy.special.polygamma(1, shape))
			
			# Don't let shape escape from valid values
			if abs(new_shape) == float("inf") or new_shape == 0:
				# Hack the shape parameter so we don't stop the loop if we land
				# near it.
				shape = new_shape
				
				# Re-start at some random place.
				new_shape = random.random()
				
			iteration += 1
			
		# Might as well grab the new value
		shape = new_shape
				
		# Now our iterative estimation of the shape parameter has converged.
		# Calculate the rate parameter
		rate = 1.0 / (1.0 / (shape * weights.sum()) * items.dot(weights).sum())

		# Set the estimated parameters
		self.parameters = [shape, rate]    

cdef class InverseGammaDistribution(GammaDistribution):
	"""
	This distribution represents an inverse gamma distribution (1/the RV ~ gamma
	with the same parameters). A distribution over non-negative floats.
	
	We cheat and don't have to do much work by inheriting from the 
	GammaDistribution.
	
	Tests:
	
	>>> random.seed(0)
	
	>>> distribution = InverseGammaDistribution(10, 0.5)
	>>> weights = numpy.array([random.random() for i in xrange(10000)])
	>>> distribution.write(sys.stdout)
	InverseGammaDistribution 10 0.5
	
	>>> sample = numpy.array([distribution.sample() for i in xrange(10000)])
	>>> distribution.from_sample(sample)
	>>> distribution.write(sys.stdout)
	InverseGammaDistribution 9.9756999562413196 0.4958491351206667
	
	"""
	
	def __init__(self, alpha, beta):
		"""
		Make a new inverse gamma distribution. Alpha is the shape parameter and 
		beta is the scale parameter.
		"""
		
		self.parameters = [alpha, beta]
		self.name = "InverseGammaDistribution"
		
	def log_probability(self, symbol):
		"""
		What's the probability of the given float under this distribution?
		"""
		
		return super(InverseGammaDistribution, self).log_probability(
			1.0 / symbol)
			
	def sample(self):
		"""
		Sample from this inverse gamma distribution and return the value
		sampled.
		"""
		
		# Invert the sample from the gamma distribution.
		return 1.0 / super(InverseGammaDistribution, self).sample()
		
	def from_sample(self, items, weights=None):
		"""
		Set the parameters of this Distribution to maximize the likelihood of 
		the given sample. Items holds some sort of sequence. If weights is 
		specified, it holds a sequence of value to weight each item by.
		"""
		
		# Fit the gamma distribution on the inverted items.
		super(InverseGammaDistribution, self).from_sample(1.0 / 
			numpy.asarray(items), weights=weights)

cdef class DiscreteDistribution(Distribution):
	"""
	A discrete distribution, made up of characters and their probabilities,
	assuming that these probabilities will sum to 1.0. 
	"""
	
	def __init__(self, characters ):
		"""
		Make a new discrete distribution with a dictionary of discrete
		characters and their probabilities, checking to see that these
		sum to 1.0. Each discrete character can be modelled as a
		Bernoulli distribution.
		"""
		
		# Store the parameters
		self.parameters = [ characters ]
		self.name = "DiscreteDistribution"


	def log_probability(self, symbol, pseudocounts=None ):
		"""
		What's the probability of the given symbol under this distribution?
		Simply the log probability value given at initiation. If the symbol
		is not part of the discrete distribution, return 0 or a pseudocount
		of .001. 
		"""

		if symbol in self.parameters[0]:
			return log( self.parameters[0][symbol] )
		else:
			if pseudocounts:
				return pseudocounts
			return NEGINF    
			
	def sample(self):
		"""
		Sample randomly from the discrete distribution, returning the character
		which was randomly generated.
		"""
		
		rand = random.random()
		for key, value in self.parameters[0].items():
			if value >= rand:
				return key
			rand -= value
	
	def from_sample( self, items, weights=None ):
		"""
		Takes in an iterable representing samples from a distribution and
		turn it into a discrete distribution. If no weights are provided,
		each sample is weighted equally. If weights are provided, they are
		normalized to sum to 1 and used.
		"""

		n = len(items)
		if weights:
			weights = numpy.array(weights) / numpy.sum(weights)
		else:
			weights = numpy.ones(n) / n

		characters = {}
		for character, weight in it.izip( items, weights ):
			try:
				characters[character] += 1. * weight
			except KeyError:
				characters[character] = 1. * weight

		self.parameters = [ characters ]

cdef class LambdaDistribution(Distribution):
	"""
	A distribution which takes in an arbitrary lambda function, and returns
	probabilities associated with whatever that function gives. For example...

	func = lambda x: log(1) if 2 > x > 1 else log(0)
	distribution = LambdaDistribution( func )
	print distribution.log_probability( 1 ) # 1
	print distribution.log_probability( -100 ) # 0

	This assumes the lambda function returns the log probability, not the
	untransformed probability.
	"""
	
	def __init__(self, lambda_funct ):
		"""
		Takes in a lambda function and stores it. This function should return
		the log probability of seeing a certain input.
		"""

		# Store the parameters
		self.parameters = [lambda_funct]
		self.name = "LambdaDistribution"
		
	def log_probability(self, symbol):
		"""
		What's the probability of the given float under this distribution?
		"""

		return self.parameters[0](symbol)

cdef class GaussianKernelDensity( Distribution ):
	"""
	A quick way of storing points to represent a Gaussian kernel density in one
	dimension. Takes in the points at initialization, and calculates the log of
	the sum of the Gaussian distance of the new point from every other point.
	"""

	def __init__( self, points, bandwidth=1, weights=None ):
		"""
		Take in points, bandwidth, and appropriate weights. If no weights
		are provided, a uniform weight of 1/n is provided to each point.
		Weights are scaled so that they sum to 1. 
		"""

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

		self.points = numpy.array( points )
		self.parameters = [ self.points, bandwidth, self.weights ]
		self.name = "GaussianKernelDensity"

	def log_probability( self, symbol ):
		"""
		What's the probability of a given float under this distribution? It's
		the sum of the distances of the symbol from every point stored in the
		density. Bandwidth is defined at the beginning. A wrapper for the
		cython function which does math.
		"""

		return self._log_probability( symbol )

	cdef double _log_probability( self, double symbol ):
		"""
		Actually calculate it here.
		"""
		cdef double bandwidth = self.parameters[1]
		cdef double mu, scalar = 1.0 / SQRT_2_PI
		cdef int i = 0, n = len(self.parameters[0])
		cdef double distribution_prob = 0, point_prob

		for i in xrange( n ):
			# Go through each point sequentially
			mu = self.parameters[0][i]

			# Calculate the probability under that point
			point_prob = scalar * \
				cexp( -0.5 * (( mu-symbol ) / bandwidth) ** 2 )

			# Scale that point according to the weight 
			distribution_prob += point_prob * self.parameters[2][i]

		# Return the log of the sum of the probabilities
		return _log( distribution_prob )

	def sample( self ):
		"""
		Generate a random sample from this distribution. This is done by first
		selecting a random point, weighted by weights if the points are weighted
		or uniformly if not, and then randomly sampling from that point's PDF.
		"""

		mu = numpy.random.choice( self.parameters[0], p=self.parameters[2] )
		return random.gauss( mu, self.parameters[1] )

	def from_sample( self, points, weights=None ):
		"""
		Replace the points, training without inertia.
		"""

		self.points = numpy.array( points )

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

cdef class UniformKernelDensity( Distribution ):
	"""
	A quick way of storing points to represent an Exponential kernel density in
	one dimension. Takes in points at initialization, and calculates the log of
	the sum of the Gaussian distances of the new point from every other point.
	"""

	def __init__( self, points, bandwidth=1, weights=None ):
		"""
		Take in points, bandwidth, and appropriate weights. If no weights
		are provided, a uniform weight of 1/n is provided to each point.
		Weights are scaled so that they sum to 1. 
		"""

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

		self.points = numpy.array( points )
		self.parameters = [ self.points, bandwidth, self.weights ]
		self.name = "UniformKernelDensity"

	def log_probability( self, symbol ):
		"""
		What's the probability ofa given float under this distribution? It's
		the sum of the distances from the symbol calculated under individual
		exponential distributions. A wrapper for the cython function.
		"""

		return self._log_probability( symbol )

	cdef _log_probability( self, double symbol ):
		"""
		Actually do math here.
		"""

		cdef double mu
		cdef double distribution_prob=0, point_prob
		cdef int i = 0, n = len(self.parameters[0])

		for i in xrange( n ):
			# Go through each point sequentially
			mu = self.parameters[0][i]

			# The good thing about uniform distributions if that
			# you just need to check to make sure the point is within
			# a bandwidth.
			if abs( mu - symbol ) <= self.parameters[1]:
				point_prob = 1

			# Properly weight the point before adding it to the sum
			distribution_prob += point_prob * self.parameters[2][i]

		# Return the log of the sum of probabilities
		return _log( distribution_prob )
	
	def sample( self ):
		"""
		Generate a random sample from this distribution. This is done by first
		selecting a random point, weighted by weights if the points are weighted
		or uniformly if not, and then randomly sampling from that point's PDF.
		"""

		mu = numpy.random.choice( self.points, p=self.weights )
		bandwidth = self.parameters[1]
		return random.uniform( mu-bandwidth, mu+bandwidth )

	def from_sample( self, points, weights=None ):
		"""
		Replace the points, training without inertia.
		"""

		self.points = numpy.array( points )

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

cdef class TriangleKernelDensity( Distribution ):
	"""
	A quick way of storing points to represent an Exponential kernel density in
	one dimension. Takes in points at initialization, and calculates the log of
	the sum of the Gaussian distances of the new point from every other point.
	"""

	def __init__( self, points, bandwidth=1, weights=None ):
		"""
		Take in points, bandwidth, and appropriate weights. If no weights
		are provided, a uniform weight of 1/n is provided to each point.
		Weights are scaled so that they sum to 1. 
		"""

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

		self.points = numpy.array( points )
		self.parameters = [ self.points, bandwidth, self.weights ]
		self.name = "TriangleKernelDensity"

	def log_probability( self, symbol ):
		"""
		What's the probability of a given float under this distribution? It's
		the sum of the distances from the symbol calculated under individual
		exponential distributions. A wrapper for the cython function.
		""" 

		return self._log_probability( symbol )

	cdef double _log_probability( self, double symbol ):
		"""
		Actually do math here.
		"""

		cdef double bandwidth = self.parameters[1]
		cdef double mu
		cdef double distribution_prob=0, point_prob
		cdef int i = 0, n = len(self.parameters[0])

		for i in xrange( n ):
			# Go through each point sequentially
			mu = self.parameters[0][i]

			# Calculate the probability for each point
			point_prob = bandwidth - abs( mu - symbol ) 
			if point_prob < 0:
				point_prob = 0 

			# Properly weight the point before adding to the sum
			distribution_prob += point_prob * self.parameters[2][i]

		# Return the log of the sum of probabilities
		return _log( distribution_prob )

	def sample( self ):
		"""
		Generate a random sample from this distribution. This is done by first
		selecting a random point, weighted by weights if the points are weighted
		or uniformly if not, and then randomly sampling from that point's PDF.
		"""

		mu = numpy.random.choice( self.points, p=self.weights )
		bandwidth = self.parameters[1]
		return random.triangular( mu-bandwidth, mu+bandwidth, mu )

	def from_sample( self, points, weights=None ):
		"""
		Replace the points, training without inertia.
		"""

		self.points = numpy.array( points )

		n = len(points)
		if weights:
			self.weights = numpy.array(weights) / numpy.sum(weights)
		else:
			self.weights = numpy.ones( n ) / n 

cdef class MixtureDistribution( Distribution ):
	"""
	Allows you to create an arbitrary mixture of distributions. There can be
	any number of distributions, include any permutation of types of
	distributions. Can also specify weights for the distributions.
	"""

	def __init__( self, distributions, weights=None ):
		"""
		Take in the distributions and appropriate weights. If no weights
		are provided, a uniform weight of 1/n is provided to each point.
		Weights are scaled so that they sum to 1. 
		"""
		n = len(distributions)
		if weights:
			self.weights = numpy.array( weights ) / numpy.sum( weights )
		else:
			self.weights = numpy.ones(n) / n

		self.parameters = [ distributions, self.weights ]
		self.name = "MixtureDistribution"

	def __str__(self):
		"""
		Represent this distribution in a human-readable form.
		"""
		
		return "{}({}, {})".format(self.name, map(str, self.parameters[0]),
			str(self.parameters[1]) )

	def log_probability( self, symbol ):
		"""
		What's the probability of a given float under this mixture? It's
		the log-sum-exp of the distances from the symbol calculated under all
		distributions. Currently in python, not cython, to allow for dovetyping
		of both numeric and not-necessarily-numeric distributions. 
		"""

		(d, w), n = self.parameters, len(self.parameters)
		return _log( numpy.sum([ cexp( d[i].log_probability(symbol) ) \
			* w[i] for i in xrange(n) ]) )

	def sample( self ):
		"""
		Sample from the mixture. First, choose a distribution to sample from
		according to the weights, then sample from that distribution. 
		"""

		i = random.random()
		for d, w in zip( self.parameters ):
			if w > i:
				return d.sample()
			i -= w 

	def from_sample( self, items, weights=None ):
		"""
		Currently not implemented, but should be some form of GMM estimation
		on the data. The issue would be that the MixtureModel can be more
		expressive than a GMM estimation, since GMM estimation is one type
		of distribution.
		"""

		raise NotImplementedError

	def write(self, stream):
		"""
		Write a line to the stream that can be used to reconstruct this 
		distribution.
		"""
		
		# Format is name of distribution in distribution lookup table, and then
		# all the parameters
		stream.write("{} {} {}\n".format( self.name, 
			"[ " + ", ".join( map( str, self.parameters[0]) ) + " ]",
			str( list(self.parameters[1]) ) ) )

cdef class State(object):
	"""
	Represents a state in an HMM. Holds emission distribution, but not
	transition distribution, because that's stored in the graph edges.
	"""
	
	cdef public Distribution distribution
	cdef public str name
	cdef public str identity
	cdef public double weight

	def __init__(self, distribution, name=None, weight=None, identity=None ):
		"""
		Make a new State emitting from the given distribution. If distribution 
		is None, this state does not emit anything. A name, if specified, will 
		be the state's name when presented in output. Name may not contain 
		spaces or newlines, and must be unique within an HMM. Identity is a
		store of the id property, to allow for multiple states to have the same
		name but be uniquely identifiable. 
		"""
		
		# Save the distribution
		self.distribution = distribution
		
		# Save the name
		self.name = name or str(id(str))

		# Save the id
		if identity is not None:
			self.identity = str(identity)
		else:
			self.identity = str(id(self))

		self.weight = weight or 1.

	def is_silent(self):
		"""
		Return True if this state is silent (distribution is None) and False 
		otherwise.
		"""
		
		return self.distribution is None

	def tied_copy( self ):
		"""
		Return a copy of this state where the distribution is tied to the
		distribution of this state.
		"""

		return State( distribution=self.distribution, name=self.name )
		
	def copy( self ):
		"""
		Return a hard copy of this state.
		"""

		return State( **self.__dict__ )
			
	def __str__(self):
		"""
		Represent this state with it's name.
		"""
		
		if self.is_silent():
			return "{} (silent)".format(self.name)
		else:
			return "{}: {}".format(self.name, str(self.distribution))
		
	def __repr__(self):
		"""
		Represent this state uniquely.
		"""
		
		return "State({}, {}, {})".format(
			self.name, str(self.distribution), self.identity)
		
	def write(self, stream):
		"""
		Write this State (and its Distribution) to the given stream.
		
		Format: name, followed by "*" if the state is silent.
		If not followed by "*", the next line contains the emission
		distribution.
		"""
		
		name = self.name.replace( " ", "_" ) 
		stream.write( "{} {} {}\n".format( 
			self.identity, name, str( self.distribution ) ) )
			
	@classmethod
	def read(cls, stream):
		"""
		Read a State from the given stream, in the format output by write().
		"""
		
		# Read a line
		line = stream.readline()
		
		if line == "":
			raise EOFError("End of file while reading state.")
			
		# Spilt the line up
		parts = line.strip().split()
		
		# parts[0] holds the state's name, and parts[1] holds the rest of the
		# state information, so we can just evaluate it.
		identity, name, state_info = parts[0], parts[1], ' '.join( parts[2:] )
		return eval( "State( {}, name='{}', identity='{}' )".format( 
			state_info, name, identity ) )

cdef class Model(object):
	"""
	Represents a Hidden Markov Model.
	
	Tests:
	Re-seed the RNG
	>>> random.seed(0)

	>>> s1 = State(UniformDistribution(0.0, 1.0), name="S1")
	>>> s2 = State(UniformDistribution(0.5, 1.5), name="S2")
	>>> s3 = State(UniformDistribution(-1.0, 1.0), name="S3")
	
	Make a simple 2-state model
	>>> model_a = Model(name="A")
	>>> model_a.add_state(s1)
	>>> model_a.add_state(s2)
	>>> model_a.add_transition(s1, s1, 0.70)
	>>> model_a.add_transition(s1, s2, 0.25)
	>>> model_a.add_transition(s1, model_a.end, 0.05)
	>>> model_a.add_transition(s2, s2, 0.70)
	>>> model_a.add_transition(s2, s1, 0.25)
	>>> model_a.add_transition(s2, model_a.end, 0.05)
	>>> model_a.add_transition(model_a.start, s1, 0.5)
	>>> model_a.add_transition(model_a.start, s2, 0.5)
	
	Make another model with that model as a component
	>>> model_b = Model(name="B")
	>>> model_b.add_state(s3)
	>>> model_b.add_transition(model_b.start, s3, 1.0)
	>>> model_b.add_model(model_a)
	>>> model_b.add_transition(s3, model_a.start, 1.0)
	>>> model_b.add_transition(model_a.end, model_b.end, 1.0) 
	
	>>> model_b.bake()
	
	>>> model_b.write(sys.stdout)
	B 7
	A-end *
	A-start *
	B-end *
	B-start *
	S1
	UniformDistribution 0.0 1.0
	S2
	UniformDistribution 0.5 1.5
	S3
	UniformDistribution -1.0 1.0
	A-end B-end 1.0
	A-start S1 0.5
	A-start S2 0.5
	B-start S3 1.0
	S1 A-end 0.05
	S1 S1 0.7
	S1 S2 0.25
	S2 A-end 0.05
	S2 S1 0.25
	S2 S2 0.7
	S3 A-start 1.0

	
	>>> model_b.sample()
	[0.515908805880605, 1.0112747213686086, 1.2837985890347725, \
0.9765969541523558, 1.4081128851953353, 0.7818378443997038, \
0.6183689966753316, 0.9097462559682401]


	
	>>> model_b.forward([])
	-inf
	>>> model_b.forward([-0.5, 0.2, 0.2])
	-4.7387015786126137
	>>> model_b.forward([-0.5, 0.2, 0.2 -0.5])
	-inf
	>>> model_b.forward([-0.5, 0.2, 1.2, 0.8])
	-5.8196142901813221

	
	>>> model_b.backward([])
	-inf
	>>> model_b.backward([-0.5, 0.2, 0.2])
	-4.7387015786126137
	>>> model_b.backward([-0.5, 0.2, 0.2 -0.5])
	-inf
	>>> model_b.backward([-0.5, 0.2, 1.2, 0.8])
	-5.819614290181323

	
	>>> model_b.viterbi([])
	(-inf, None)
	>>> model_b.viterbi([-0.5, 0.2, 0.2])
	(-4.7387015786126137, \
[(0, State(B-start, None)), \
(1, State(S3, UniformDistribution(-1.0, 1.0))), \
(1, State(A-start, None)), \
(2, State(S1, UniformDistribution(0.0, 1.0))), \
(3, State(S1, UniformDistribution(0.0, 1.0))), \
(3, State(A-end, None)), \
(3, State(B-end, None))])
	>>> model_b.viterbi([-0.5, 0.2, 0.2 -0.5])
	(-inf, None)
	>>> model_b.viterbi([-0.5, 0.2, 1.2, 0.8])
	(-6.1249959397325044, \
[(0, State(B-start, None)), \
(1, State(S3, UniformDistribution(-1.0, 1.0))), \
(1, State(A-start, None)), \
(2, State(S1, UniformDistribution(0.0, 1.0))), \
(3, State(S2, UniformDistribution(0.5, 1.5))), \
(4, State(S2, UniformDistribution(0.5, 1.5))), \
(4, State(A-end, None)), \
(4, State(B-end, None))])
	>>> model_b.train([[-0.5, 0.2, 0.2], [-0.5, 0.2, 1.2, 0.8]], \
	transition_pseudocount=1)
	Training improvement: 4.47502955715
	Training improvement: 0.0392148069767
	Training improvement: 0.0366728072271
	Training improvement: 0.0268032628936
	Training improvement: 0.0159736872496
	Training improvement: 0.00828859233119
	Training improvement: 0.00397283392515
	Training improvement: 0.00182886240049
	Training improvement: 0.000825903775144
	Training improvement: 0.000369706973896
	Training improvement: 0.000164840436767
	Training improvement: 7.33668075608e-05
	Training improvement: 3.26281298075e-05
	Training improvement: 1.45054754273e-05
	Training improvement: 6.44768506741e-06
	Training improvement: 2.86579726017e-06
	Training improvement: 1.2737191708e-06
	Training improvement: 5.66103632638e-07
	Training improvement: 2.5160284256e-07
	Training improvement: 1.11823730498e-07
	Training improvement: 4.96994811972e-08
	Training improvement: 2.20886680058e-08
	Training improvement: 9.81718994986e-09
	Training improvement: 4.36319358421e-09
	Training improvement: 1.93919769131e-09
	Training improvement: 8.61867466284e-10
	0.16271181143980118
	>>> model_b.write(sys.stdout)
	B 7
	A-end *
	A-start *
	B-end *
	B-start *
	S1
	UniformDistribution 0.2 0.8
	S2
	UniformDistribution 0.8 1.2
	S3
	UniformDistribution -0.5 -0.5
	A-end B-end 1.0
	A-start S1 1.0
	B-start S3 1.0
	S1 A-end 0.333333333453
	S1 S1 0.333333333273
	S1 S2 0.333333333273
	S2 A-end 0.499999999865
	S2 S1 2.69609280849e-10
	S2 S2 0.499999999865
	S3 A-start 1.0
	
	>>> model_b.forward([])
	-inf
	>>> model_b.forward([-0.5, 0.2, 0.2])
	-1.1755733296244983
	>>> model_b.forward([-0.5, 0.2, 0.2 -0.5])
	-inf
	>>> model_b.forward([-0.5, 0.2, 1.2, 0.8])
	-0.14149956275300468
	"""
	cdef public str name
	cdef public object start, end, graph
	cdef public list states
	cdef public int start_index, end_index, silent_start
	cdef int [:] in_edge_count, in_transitions, out_edge_count, out_transitions
	cdef double [:] in_transition_log_probabilities
	cdef double [:] in_transition_pseudocounts
	cdef double [:] out_transition_log_probabilities
	cdef double [:] out_transition_pseudocounts
	cdef double [:] state_weights
	cdef int [:] tied_state_count
	cdef int [:] tied
	cdef int finite

	def __init__(self, name=None, start=None, end=None):
		"""
		Make a new Hidden Markov Model. Name is an optional string used to name
		the model when output. Name may not contain spaces or newlines.
		
		If start and end are specified, they are used as start and end states 
		and new start and end states are not generated.
		"""
		
		# Save the name or make up a name.
		self.name = name or str( id(self) )

		# This holds a directed graph between states. Nodes in that graph are
		# State objects, so they're guaranteed never to conflict when composing
		# two distinct models
		self.graph = networkx.DiGraph()
		
		# Save the start or make up a start
		self.start = start or State( None, name=self.name + "-start" )

		# Save the end or make up a end
		self.end = end or State( None, name=self.name + "-end" )
		
		# Put start and end in the graph
		self.graph.add_node(self.start)
		self.graph.add_node(self.end)
	
	def __str__(self):
		"""
		Represent this HMM with it's name and states.
		"""
		
		return "{}:\n\t{}".format(self.name, "\n\t".join(map(str, self.states)))

	def is_infinite( self ):
		"""
		Returns whether or not the HMM is infinite, or finite. This is
		determined in the bake method, based on if there are any edges to the
		end state or not. Can only be used after a model is baked.
		"""

		return self.finite == 0

	def add_state(self, state):
		"""
		Adds the given State to the model. It must not already be in the model,
		nor may it be part of any other model that will eventually be combined
		with this one.
		"""
		
		# Put it in the graph
		self.graph.add_node(state)
		
	def add_transition(self, a, b, probability, pseudocount=None):
		"""
		Add a transition from state a to state b with the given (non-log)
		probability. Both states must be in the HMM already. self.start and
		self.end are valid arguments here. Probabilities will be normalized
		such that every node has edges summing to 1. leaving that node, but
		only when the model is baked.
		"""
		
		# If a pseudocount is specified, use it, otherwise use the probability.
		# The pseudocounts come up during training, when you want to specify
		# custom pseudocount weighting schemes per edge, in order to make the
		# model converge to that scheme given no observations. 
		pseudocount = pseudocount or probability

		# Add the transition
		self.graph.add_edge(a, b, weight=log(probability), 
			pseudocount=pseudocount)
		
	def add_model(self, other):
		"""
		Given another Model, add that model's contents to us. Its start and end
		states become silent states in our model.
		"""
		
		# Unify the graphs (requiring disjoint states)
		self.graph = networkx.union(self.graph, other.graph)
		
		# Since the nodes in the graph are references to Python objects,
		# other.start and other.end and self.start and self.end still mean the
		# same State objects in the new combined graph.

	def concatenate_model( self, other ):
		"""
		Given another model, concatenate it in such a manner that you simply
		add a transition of probability 1 from self.end to other.start, and
		end at other.end. One of these silent states will be removed when
		the model is baked, due to the graph simplification routine.
		"""

		# Unify the graphs (requiring disjoint states)
		self.graph = networkx.union( self.graph, other.graph )
		
		# Connect the two graphs
		self.add_transition( self.end, other.start, 1.00 )

		# Move the end to other.end
		self.end = other.end

	def draw(self, **kwargs):
		"""
		Draw this model's graph using NetworkX and matplotlib. Blocks until the
		window displaying the graph is closed.
		
		Note that this relies on networkx's built-in graphing capabilities (and 
		not Graphviz) and thus can't draw self-loops.

		See networkx.draw_networkx() for the keywords you can pass in.
		"""
		
		networkx.draw(self.graph, **kwargs)
		pyplot.show()
		   
	def bake( self, verbose=False, merge="all" ): 
		"""
		Finalize the topology of the model, and assign a numerical index to
		every state. This method must be called before any of the probability-
		calculating methods.
		
		This fills in self.states (a list of all states in order) and 
		self.transition_log_probabilities (log probabilities for transitions), 
		as well as self.start_index and self.end_index, and self.silent_start 
		(the index of the first silent state).

		The option verbose will return a log of the changes made to the model
		due to normalization or merging. Merging has three options, "all",
		"partial", and None. None will keep the underlying graph structure
		completely in tact. "Partial" will merge silent states where one
		has a probability 1.0 transition to the other, to simplify the model
		without changing the underlying meaning. "All" will merge any silent
		state which has a probability 1.0 transition to any other state,
		silent or character-generating either. This may not be desirable as
		some silent states are useful for bookkeeping purposes.
		"""

		# Go through the model and delete any nodes which have no edges leading
		# to it, or edges leading out of it. This gets rid of any states with
		# no edges in or out, as well as recursively removing any chains which
		# are impossible for the viterbi path to touch.
		self.in_edge_count = numpy.zeros( len( self.graph.nodes() ), 
			dtype=numpy.int32 ) 
		self.out_edge_count = numpy.zeros( len( self.graph.nodes() ), 
			dtype=numpy.int32 )
		
		merge = merge.lower() if merge else None
		while merge == 'all':
			merge_count = 0

			# Reindex the states based on ones which are still there
			prestates = self.graph.nodes()
			indices = { prestates[i]: i for i in xrange( len( prestates ) ) }

			# Go through all the edges, summing in and out edges
			for a, b in self.graph.edges():
				self.out_edge_count[ indices[a] ] += 1
				self.in_edge_count[ indices[b] ] += 1
				
			# Go through each state, and if either in or out edges are 0,
			# remove the edge.
			for i in xrange( len( prestates ) ):
				if prestates[i] is self.start or prestates[i] is self.end:
					continue

				if self.in_edge_count[i] == 0:
					merge_count += 1
					self.graph.remove_node( prestates[i] )

					if verbose:
						print "Orphan state {} removed due to no edges \
							leading to it".format(prestates[i].name )

				elif self.out_edge_count[i] == 0:
					merge_count += 1
					self.graph.remove_node( prestates[i] )

					if verbose:
						print "Orphan state {} removed due to no edges \
							leaving it".format(prestates[i].name )

			if merge_count == 0:
				break

		# Go through the model checking to make sure out edges sum to 1.
		# Normalize them to 1 if this is not the case.
		for state in self.graph.nodes():

			# Perform log sum exp on the edges to see if they properly sum to 1
			out_edges = round( numpy.sum( map( lambda x: numpy.e**x['weight'], 
				self.graph.edge[state].values() ) ), 8 )

			# The end state has no out edges, so will be 0
			if out_edges != 1. and state != self.end:
				# Issue a notice if verbose is activated
				if verbose:
					print "{} : {} summed to {}, normalized to 1.0"\
						.format( self.name, state.name, out_edges )

				# Reweight the edges so that the probability (not logp) sums
				# to 1.
				for edge in self.graph.edge[state].values():
					edge['weight'] = edge['weight'] - log( out_edges )

		# Automatically merge adjacent silent states attached by a single edge
		# of 1.0 probability, as that adds nothing to the model. Traverse the
		# edges looking for 1.0 probability edges between silent states.
		while merge in ['all', 'partial']:
			# Repeatedly go through the model until no merges take place.
			merge_count = 0

			for a, b, e in self.graph.edges( data=True ):
				# Since we may have removed a or b in a previous iteration,
				# a simple fix is to just check to see if it's still there
				if a not in self.graph.nodes() or b not in self.graph.nodes():
					continue

				if a == self.start or b == self.end:
					continue

				# If a silent state has a probability 1 transition out
				if e['weight'] == 0.0 and a.is_silent():

					# Make sure the transition is an appropriate merger
					if merge=='all' or ( merge=='partial' and b.is_silent() ):

						# Go through every transition to that state 
						for x, y, d in self.graph.edges( data=True ):

							# Make sure that the edge points to the current node
							if y is a:
								# Increment the edge counter
								merge_count += 1

								# Remove the edge going to that node
								self.graph.remove_edge( x, y )

								# Add a new edge going to the new node
								self.graph.add_edge( x, b, weight=d['weight'],
									pseudocount=max( 
										e['pseudocount'], d['pseudocount'] ) )

								# Log the event
								if verbose:
									print "{} : {} - {} merged".format(
										self.name, a, b)

						# Remove the state now that all edges are removed
						self.graph.remove_node( a )

			if merge_count == 0:
				break

		# Detect whether or not there are loops of silent states by going
		# through every pair of edges, and ensure that there is not a cycle
		# of silent states.		
		for a, b, e in self.graph.edges( data=True ):
			for x, y, d in self.graph.edges( data=True ):
				if a is y and b is x and a.is_silent() and b.is_silent():
					print "Loop: {} - {}".format( a.name, b.name )

		states = self.graph.nodes()
		n, m = len(states), len(self.graph.edges())
		silent_states, normal_states = [], []

		for state in states:
			if state.is_silent():
				silent_states.append(state)
			else:
				normal_states.append(state)

		# We need the silent states to be in topological sort order: any
		# transition between silent states must be from a lower-numbered state
		# to a higher-numbered state. Since we ban loops of silent states, we
		# can get away with this.
		
		# Get the subgraph of all silent states
		silent_subgraph = self.graph.subgraph(silent_states)
		
		# Get the sorted silent states. Isn't it convenient how NetworkX has
		# exactly the algorithm we need?
		silent_states_sorted = networkx.topological_sort(silent_subgraph)
		
		# What's the index of the first silent state?
		self.silent_start = len(normal_states)

		# Save the master state ordering. Silent states are last and in
		# topological order, so when calculationg forward algorithm
		# probabilities we can just go down the list of states.
		self.states = normal_states + silent_states_sorted 
		
		# We need a good way to get transition probabilities by state index that
		# isn't N^2 to build or store. So we will need a reverse of the above
		# mapping. It's awkward but asymptotically fine.
		indices = { self.states[i]: i for i in xrange(n) }

		# Create a sparse representation of the tied states in the model. This
		# is done in the same way of the transition, by having a vector of
		# counts, and a vector of the IDs that the state is tied to.
		self.tied_state_count = numpy.zeros( self.silent_start+1, 
			dtype=numpy.int32 )

		for i in xrange( self.silent_start ):
			for j in xrange( self.silent_start ):
				if i == j:
					continue
				if self.states[i].distribution is self.states[j].distribution:
					self.tied_state_count[i+1] += 1

		# Take the cumulative sum in order to get indexes instead of counts,
		# with the last index being the total number of ties.
		self.tied_state_count = numpy.cumsum( self.tied_state_count,
			dtype=numpy.int32 )

		self.tied = numpy.zeros( self.tied_state_count[-1], 
			dtype=numpy.int32 ) - 1

		for i in xrange( self.silent_start ):
			for j in xrange( self.silent_start ):
				if i == j:
					continue
					
				if self.states[i].distribution is self.states[j].distribution:
					# Begin at the first index which belongs to state i...
					start = self.tied_state_count[i]

					# Find the first non -1 entry in order to put our index.
					while self.tied[start] != -1:
						start += 1

					# Now that we've found a non -1 entry, put the index of the
					# state which this state is tied to in!
					self.tied[start] = j

		# Unpack the state weights
		self.state_weights = numpy.zeros( self.silent_start )
		for i in xrange( self.silent_start ):
			self.state_weights[i] = clog( self.states[i].weight )

		# This holds numpy array indexed [a, b] to transition log probabilities 
		# from a to b, where a and b are state indices. It starts out saying all
		# transitions are impossible.
		self.in_transitions = numpy.zeros( len(self.graph.edges()), 
			dtype=numpy.int32 ) - 1
		self.in_edge_count = numpy.zeros( len(self.states)+1, 
			dtype=numpy.int32 ) 
		self.out_transitions = numpy.zeros( len(self.graph.edges()), 
			dtype=numpy.int32 ) - 1
		self.out_edge_count = numpy.zeros( len(self.states)+1, 
			dtype=numpy.int32 )
		self.in_transition_log_probabilities = numpy.zeros(
			len( self.graph.edges() ) )
		self.out_transition_log_probabilities = numpy.zeros(
			len( self.graph.edges() ) )
		self.in_transition_pseudocounts = numpy.zeros( 
			len( self.graph.edges() ) )
		self.out_transition_pseudocounts = numpy.zeros(
			len( self.graph.edges() ) )

		# Now we need to find a way of storing in-edges for a state in a manner
		# that can be called in the cythonized methods below. This is basically
		# an inversion of the graph. We will do this by having two lists, one
		# list size number of nodes + 1, and one list size number of edges.
		# The node size list will store the beginning and end values in the
		# edge list that point to that node. The edge list will be ordered in
		# such a manner that all edges pointing to the same node are grouped
		# together. This will allow us to run the algorithms in time
		# nodes*edges instead of nodes*nodes.

		for a, b in self.graph.edges_iter():
			# Increment the total number of edges going to node b.
			self.in_edge_count[ indices[b]+1 ] += 1
			# Increment the total number of edges leaving node a.
			self.out_edge_count[ indices[a]+1 ] += 1

		# Determine if the model is infinite or not based on the number of edges
		# to the end state
		if self.in_edge_count[ indices[ self.end ]+1 ] == 0:
			self.finite = 0
		else:
			self.finite = 1

		# Take the cumulative sum so that we can associat
		self.in_edge_count = numpy.cumsum(self.in_edge_count, 
            dtype=numpy.int32)
		self.out_edge_count = numpy.cumsum(self.out_edge_count, 
            dtype=numpy.int32 )

		# Now we go through the edges again in order to both fill in the
		# transition probability matrix, and also to store the indices sorted
		# by the end-node.
		for a, b, data in self.graph.edges_iter(data=True):
			# Put the edge in the dict. Its weight is log-probability
			start = self.in_edge_count[ indices[b] ]

			# Start at the beginning of the section marked off for node b.
			# If another node is already there, keep walking down the list
			# until you find a -1 meaning a node hasn't been put there yet.
			while self.in_transitions[ start ] != -1:
				if start == self.in_edge_count[ indices[b]+1 ]:
					break
				start += 1

			self.in_transition_log_probabilities[ start ] = data['weight']
			self.in_transition_pseudocounts[ start ] = data['pseudocount']

			# Store transition info in an array where the in_edge_count shows
			# the mapping stuff.
			self.in_transitions[ start ] = indices[a]

			# Now do the same for out edges
			start = self.out_edge_count[ indices[a] ]

			while self.out_transitions[ start ] != -1:
				if start == self.out_edge_count[ indices[a]+1 ]:
					break
				start += 1

			self.out_transition_log_probabilities[ start ] = data['weight']
			self.out_transition_pseudocounts[ start ] = data['pseudocount']
			self.out_transitions[ start ] = indices[b]  

		# This holds the index of the start state
		try:
			self.start_index = indices[self.start]
		except KeyError:
			raise SyntaxError( "Model.start has been deleted, leaving the \
				model with no start. Please ensure it has a start." )
		# And the end state
		try:
			self.end_index = indices[self.end]
		except KeyError:
			raise SyntaxError( "Model.end has been deleted, leaving the \
				model with no end. Please ensure it has an end." )

	def sample( self, length=0, path=False ):
		"""
		Generate a sequence from the model. Returns the sequence generated, as a
		list of emitted items. The model must have been baked first in order to 
		run this method.

		If a length is specified and the HMM is infinite (no edges to the
		end state), then that number of samples will be randomly generated.
		If the length is specified and the HMM is finite, the method will
		attempt to generate a prefix of that length. Currently it will force
		itself to not take an end transition unless that is the only path,
		making it not a true random sample on a finite model.

		WARNING: If the HMM is infinite, must specify a length to use.

		If path is True, will return a tuple of ( sample, path ), where path is
		the path of hidden states that the sample took. Otherwise, the method
		will just return the path. Note that the path length may not be the same
		length as the samples, as it will return silent states it visited, but
		they will not generate an emission.
		"""
		
		return self._sample( length, path )

	cdef list _sample( self, int length, int path ):
		"""
		Perform a run of sampling.
		"""

		cdef int i, j, k, l, li, m=len(self.states)
		cdef double cumulative_probability
		cdef double [:,:] transition_probabilities = numpy.zeros( (m,m) )
		cdef double [:] cum_probabilities = numpy.zeros( 
			len(self.out_transitions) )

		cdef int [:] out_edges = self.out_edge_count

		for k in xrange( m ):
			cumulative_probability = 0.
			for l in xrange( out_edges[k], out_edges[k+1] ):
				cumulative_probability += cexp( 
					self.out_transition_log_probabilities[l] )
				cum_probabilities[l] = cumulative_probability 

		# This holds the numerical index of the state we are currently in.
		# Start in the start state
		i = self.start_index
		
		# Record the number of samples
		cdef int n = 0
		# Define the list of emissions, and the path of hidden states taken
		cdef list emissions = [], sequence_path = []
		cdef State state
		cdef double sample

		while i != self.end_index:
			# Get the object associated with this state
			state = self.states[i]

			# Add the state to the growing path
			sequence_path.append( state )
			
			if not state.is_silent():
				# There's an emission distribution, so sample from it
				emissions.append( state.distribution.sample() )
				n += 1

			# If we've reached the specified length, return the appropriate
			# values
			if length != 0 and n >= length:
				if path:
					return [emissions, sequence_path]
				return emissions

			# What should we pick as our next state?
			# Generate a number between 0 and 1 to make a weighted decision
			# as to which state to jump to next.
			sample = random.random()
			
			# Save the last state id we were in
			j = i

			# Find out which state we're supposed to go to by comparing the
			# random number to the list of cumulative probabilities for that
			# state, and then picking the selected state.
			for k in xrange( out_edges[i], out_edges[i+1] ):
				if cum_probabilities[k] > sample:
					i = self.out_transitions[k]
					break

			# If the user specified a length, and we're not at that length, and
			# we're in an infinite HMM, we want to avoid going to the end state
			# if possible. If there is only a single probability 1 end to the
			# end state we can't avoid it, otherwise go somewhere else.
			if length != 0 and self.finite == 1 and i == self.end_index:
				# If there is only one transition...
				if len( xrange( out_edges[j], out_edges[j+1] ) ) == 1:
					# ...and that transition goes to the end of the model...
					if self.out_transitions[ out_edges[j] ] == self.end_index:
						# ... then end the sampling, as nowhere else to go.
						break

				# Take the cumulative probability of not going to the end state
				cumulative_probability = 0.
				for k in xrange( out_edges[k], out_edges[k+1] ):
					if self.out_transitions[k] != self.end_index:
						cumulative_probability += cum_probabilities[k]

				# Randomly select a number in that probability range
				sample = random.uniform( 0, cumulative_probability )

				# Select the state is corresponds to
				for k in xrange( out_edges[i], out_edges[i+1] ):
					if cum_probabilities[k] > sample:
						i = self.out_transitions[k]
						break
		
		# Done! Return either emissions, or emissions and path.
		if path:
			sequence_path.append( self.end )
			return [emissions, sequence_path]
		return emissions

	def forward( self, sequence ):
		'''
		Python wrapper for the forward algorithm, calculating probability by
		going forward through a sequence. Returns the full forward DP matrix.
		Each index i, j corresponds to the sum-of-all-paths log probability
		of starting at the beginning of the sequence, and aligning observations
		to hidden states in such a manner that observation i was aligned to
		hidden state j. Uses row normalization to dynamically scale each row
		to prevent underflow errors.

		If the sequence is impossible, will return a matrix of nans.

		input
			sequence: a list (or numpy array) of observations

		output
			A n-by-m matrix of floats, where n = len( sequence ) and
			m = len( self.states ). This is the DP matrix for the
			forward algorithm.

		See also: 
			- Silent state handling taken from p. 71 of "Biological
		Sequence Analysis" by Durbin et al., and works for anything which
		does not have loops of silent states.
			- Row normalization technique explained by 
		http://www.cs.sjsu.edu/~stamp/RUA/HMM.pdf on p. 14.
		'''

		return numpy.array( self._forward( numpy.array( sequence ) ) )

	cdef double [:,:] _forward( self, numpy.ndarray sequence ):
		"""
		Run the forward algorithm, and return the matrix of log probabilities
		of each segment being in each hidden state. 
		
		Initializes self.f, the forward algorithm DP table.
		"""

		cdef unsigned int D_SIZE = sizeof( double )
		cdef int i = 0, k, ki, l, n = len( sequence ), m = len( self.states ), j = 0
		cdef double [:,:] f, e
		cdef double log_probability
		cdef State s
		cdef Distribution d
		cdef int [:] in_edges = self.in_edge_count
		cdef double [:] c

		# Initialize the DP table. Each entry i, k holds the log probability of
		# emitting i symbols and ending in state k, starting from the start
		# state.
		f = cvarray( shape=(n+1, m), itemsize=D_SIZE, format='d' )
		c = numpy.zeros( (n+1) )

		# Initialize the emission table, which contains the probability of
		# each entry i, k holds the probability of symbol i being emitted
		# by state k 
		e = cvarray( shape=(n,self.silent_start), itemsize=D_SIZE, format='d') 
		for k in xrange( n ):
			for i in xrange( self.silent_start ):
				s = <State>self.states[i]
				d = <Distribution>(s.distribution)
				log_probability = d.log_probability( sequence[k] )
				e[k, i] = log_probability

		# We must start in the start state, having emitted 0 symbols        
		for i in xrange(m):
			f[0, i] = NEGINF
		f[0, self.start_index] = 0.

		for l in xrange( self.silent_start, m ):
			# Handle transitions between silent states before the first symbol
			# is emitted. No non-silent states have non-zero probability yet, so
			# we can ignore them.
			if l == self.start_index:
				# Start state log-probability is already right. Don't touch it.
				continue

			# This holds the log total transition probability in from 
			# all current-step silent states that can have transitions into 
			# this state.  
			log_probability = NEGINF
			for k in xrange( in_edges[l], in_edges[l+1] ):
				ki = self.in_transitions[k]
				if ki < self.silent_start or ki >= l:
					continue

				# For each current-step preceeding silent state k
				#log_probability = pair_lse( log_probability, 
				#	f[0, k] + self.transition_log_probabilities[k, l] )
				log_probability = pair_lse( log_probability,
					f[0, ki] + self.in_transition_log_probabilities[k] )

			# Update the table entry
			f[0, l] = log_probability

		for i in xrange( n ):
			for l in xrange( self.silent_start ):
				# Do the recurrence for non-silent states l
				# This holds the log total transition probability in from 
				# all previous states

				log_probability = NEGINF
				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]

					# For each previous state k
					log_probability = pair_lse( log_probability,
						f[i, ki] + self.in_transition_log_probabilities[k] )

				# Now set the table entry for log probability of emitting 
				# index+1 characters and ending in state l
				f[i+1, l] = log_probability + e[i, l]

			for l in xrange( self.silent_start, m ):
				# Now do the first pass over the silent states
				# This holds the log total transition probability in from 
				# all current-step non-silent states
				log_probability = NEGINF
				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]
					if ki >= self.silent_start:
						continue

					# For each current-step non-silent state k
					log_probability = pair_lse( log_probability,
						f[i+1, ki] + self.in_transition_log_probabilities[k] )

				# Set the table entry to the partial result.
				f[i+1, l] = log_probability

			for l in xrange( self.silent_start, m ):
				# Now the second pass through silent states, where we account
				# for transitions between silent states.

				# This holds the log total transition probability in from 
				# all current-step silent states that can have transitions into 
				# this state.
				log_probability = NEGINF
				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]
					if ki < self.silent_start or ki >= l:
						continue

					# For each current-step preceeding silent state k
					log_probability = pair_lse( log_probability,
						f[i+1, ki] + self.in_transition_log_probabilities[k] )

				# Add the previous partial result and update the table entry
				f[i+1, l] = pair_lse( f[i+1, l], log_probability )

			# Now calculate the normalizing weight for this row, as described
			# here: http://www.cs.sjsu.edu/~stamp/RUA/HMM.pdf
			for l in xrange( m ):
				c[i+1] += cexp( f[i+1, l] )

			# Convert to log space, and subtract, instead of invert and multiply
			c[i+1] = clog( c[i+1] )
			for l in xrange( m ):
				f[i+1, l] -= c[i+1]

		# Go through and recalculate every observation based on the sum of the
		# normalizing weights.
		for i in xrange( n+1 ):
			for l in xrange( m ):
				for k in xrange( i+1 ):
					f[i, l] += c[k]

		# Now the DP table is filled in
		# Return the entire table
		return f

	def backward( self, sequence ):
		'''
		Python wrapper for the backward algorithm, calculating probability by
		going backward through a sequence. Returns the full forward DP matrix.
		Each index i, j corresponds to the sum-of-all-paths log probability
		of starting with observation i aligned to hidden state j, and aligning
		observations to reach the end. Uses row normalization to dynamically 
		scale each row to prevent underflow errors.

		If the sequence is impossible, will return a matrix of nans.

		input
			sequence: a list (or numpy array) of observations

		output
			A n-by-m matrix of floats, where n = len( sequence ) and
			m = len( self.states ). This is the DP matrix for the
			backward algorithm.

		See also: 
			- Silent state handling is "essentially the same" according to
		Durbin et al., so they don't bother to explain *how to actually do it*.
		Algorithm worked out from first principles.
			- Row normalization technique explained by 
		http://www.cs.sjsu.edu/~stamp/RUA/HMM.pdf on p. 14.
		'''

		return numpy.array( self._backward( numpy.array( sequence ) ) )

	cdef double [:,:] _backward( self, numpy.ndarray sequence ):
		"""
		Run the backward algorithm, and return the log probability of the given 
		sequence. Sequence is a container of symbols.
		
		Initializes self.b, the backward algorithm DP table.
		"""

		cdef unsigned int D_SIZE = sizeof( double )
		cdef int i = 0, ir, k, kr, l, li, n = len( sequence ), m = len( self.states )
		cdef double [:,:] b, e
		cdef double log_probability
		cdef State s
		cdef Distribution d
		cdef int [:] out_edges = self.out_edge_count
		cdef double [:] c

		# Initialize the DP table. Each entry i, k holds the log probability of
		# emitting the remaining len(sequence) - i symbols and ending in the end
		# state, given that we are in state k.
		b = cvarray( shape=(n+1, m), itemsize=D_SIZE, format='d' )
		c = numpy.zeros( (n+1) )

		# Initialize the emission table, which contains the probability of
		# each entry i, k holds the probability of symbol i being emitted
		# by state k 
		e = cvarray( shape=(n,self.silent_start), itemsize=D_SIZE, format='d' )

		# Calculate the emission table
		for k in xrange( n ):
			for i in xrange( self.silent_start ):
				s = <State>self.states[i]
				d = <Distribution>(s.distribution)
				log_probability = d.log_probability( sequence[k] )
				e[k, i] = log_probability

		# We must end in the end state, having emitted len(sequence) symbols
		if self.finite == 1:
			for i in xrange(m):
				b[n, i] = NEGINF
			b[n, self.end_index] = 0
		else:
			for i in xrange(self.silent_start):
				b[n, i] = e[n-1, i]
			for i in xrange(self.silent_start, m):
				b[n, i] = NEGINF

		for kr in xrange( m-self.silent_start ):
			if self.finite == 0:
				break
			# Cython arrays cannot go backwards, so modify the loop to account
			# for this.
			k = m - kr - 1

			# Do the silent states' dependencies on each other.
			# Doing it in reverse order ensures that anything we can 
			# possibly transition to is already done.
			
			if k == self.end_index:
				# We already set the log-probability for this, so skip it
				continue

			# This holds the log total probability that we go to
			# current-step silent states and then continue from there to
			# finish the sequence.
			log_probability = NEGINF
			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				if li < k+1:
					continue

				# For each possible current-step silent state we can go to,
				# take into account just transition probability
				log_probability = pair_lse( log_probability,
					b[n,li] + self.out_transition_log_probabilities[l] )

			# Now this is the probability of reaching the end state given we are
			# in this silent state.
			b[n, k] = log_probability

		for k in xrange( self.silent_start ):
			if self.finite == 0:
				break
			# Do the non-silent states in the last step, which depend on
			# current-step silent states.
			
			# This holds the total accumulated log probability of going
			# to such states and continuing from there to the end.
			log_probability = NEGINF
			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				if li < self.silent_start:
					continue

				# For each current-step silent state, add in the probability
				# of going from here to there and then continuing on to the
				# end of the sequence.
				log_probability = pair_lse( log_probability,
					b[n, li] + self.out_transition_log_probabilities[l] )

			# Now we have summed the probabilities of all the ways we can
			# get from here to the end, so we can fill in the table entry.
			b[n, k] = log_probability

		# Now that we're done with the base case, move on to the recurrence
		for ir in xrange( n ):
			#if self.finite == 0 and ir == 0:
			#	continue
			# Cython xranges cannot go backwards properly, redo to handle
			# it properly
			i = n - ir - 1
			for kr in xrange( m-self.silent_start ):
				k = m - kr - 1

				# Do the silent states' dependency on subsequent non-silent
				# states, iterating backwards to match the order we use later.
				
				# This holds the log total probability that we go to some
				# subsequent state that emits the right thing, and then continue
				# from there to finish the sequence.
				log_probability = NEGINF
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li >= self.silent_start:
						continue

					# For each subsequent non-silent state l, take into account
					# transition and emission emission probability.
					log_probability = pair_lse( log_probability,
						b[i+1, li] + self.out_transition_log_probabilities[l] +
						e[i, li] )

				# We can't go from a silent state here to a silent state on the
				# next symbol, so we're done finding the probability assuming we
				# transition straight to a non-silent state.
				b[i, k] = log_probability

			for kr in xrange( m-self.silent_start ):
				k = m - kr - 1

				# Do the silent states' dependencies on each other.
				# Doing it in reverse order ensures that anything we can 
				# possibly transition to is already done.
				
				# This holds the log total probability that we go to
				# current-step silent states and then continue from there to
				# finish the sequence.
				log_probability = NEGINF
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li < k+1:
						continue

					# For each possible current-step silent state we can go to,
					# take into account just transition probability
					log_probability = pair_lse( log_probability,
						b[i, li] + self.out_transition_log_probabilities[l] )

				# Now add this probability in with the probability accumulated
				# from transitions to subsequent non-silent states.
				b[i, k] = pair_lse( log_probability, b[i, k] )

			for k in xrange( self.silent_start ):
				# Do the non-silent states in the current step, which depend on
				# subsequent non-silent states and current-step silent states.
				
				# This holds the total accumulated log probability of going
				# to such states and continuing from there to the end.
				log_probability = NEGINF
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li >= self.silent_start:
						continue

					# For each subsequent non-silent state l, take into account
					# transition and emission emission probability.
					log_probability = pair_lse( log_probability,
						b[i+1, li] + self.out_transition_log_probabilities[l] +
						e[i, li] )

				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li < self.silent_start:
						continue

					# For each current-step silent state, add in the probability
					# of going from here to there and then continuing on to the
					# end of the sequence.
					log_probability = pair_lse( log_probability,
						b[i, li] + self.out_transition_log_probabilities[l] )

				# Now we have summed the probabilities of all the ways we can
				# get from here to the end, so we can fill in the table entry.
				b[i, k] = log_probability

			# Now calculate the normalizing weight for this row, as described
			# here: http://www.cs.sjsu.edu/~stamp/RUA/HMM.pdf
			for l in xrange( m ):
				c[i] += cexp( b[i, l] )

			# Convert to log space, and subtract, instead of invert and multiply
			c[i] = clog( c[i] )
			for l in xrange( m ):
				b[i, l] -= c[i]

		# Go through and recalculate every observation based on the sum of the
		# normalizing weights.
		for ir in xrange( n+1 ):
			i = n - ir
			for l in xrange( m ):
				for k in xrange( i, n+1 ):
					b[i, l] += c[k]

		# Now the DP table is filled in. 
		# Return the entire table.
		return b

	def forward_backward( self, sequence, tie=True ):
		"""
		Implements the forward-backward algorithm. This is the sum-of-all-paths
		log probability that you start at the beginning of the sequence, align
		observation i to silent state j, and then continue on to the end.
		Simply, it is the probability of emitting the observation given the
		state and then transitioning one step.

		If the sequence is impossible, will return (None, None)

		input
			sequence: a list (or numpy array) of observations

		output
			A tuple of the estimated log transition probabilities, and
			the DP matrix for the FB algorithm. The DP matrix has
			n rows and m columns where n is the number of observations,
			and m is the number of non-silent states.

			* The estimated log transition probabilities are a m-by-m 
			matrix where index i, j indicates the log probability of 
			transitioning from state i to state j.

			* The DP matrix for the FB algorithm contains the sum-of-all-paths
			probability as described above.

		See also: 
			- Forward and backward algorithm implementations. A comprehensive
			description of the forward, backward, and forward-background
			algorithm is here: 
			http://en.wikipedia.org/wiki/Forward%E2%80%93backward_algorithm
		"""

		return self._forward_backward( numpy.array( sequence ), tie )

	cdef tuple _forward_backward( self, numpy.ndarray sequence, int tie ):
		"""
		Actually perform the math here.
		"""

		cdef int i, k, j, l, ki, li
		cdef int m=len(self.states), n=len(sequence)
		cdef double [:,:] e, f, b
		cdef double [:,:] expected_transitions = numpy.zeros((m, m))
		cdef double [:,:] emission_weights = numpy.zeros((n, self.silent_start))

		cdef double log_sequence_probability, log_probability
		cdef double log_transition_emission_probability_sum
		cdef double norm

		cdef int [:] out_edges = self.out_edge_count
		cdef int [:] tied_states = self.tied_state_count

		cdef State s
		cdef Distribution d 

		transition_log_probabilities = numpy.zeros((m,m)) + NEGINF

		# Initialize the emission table, which contains the probability of
		# each entry i, k holds the probability of symbol i being emitted
		# by state k 
		e = numpy.zeros((n, self.silent_start))

		# Fill in both the F and B DP matrices.
		f = self.forward( sequence )
		b = self.backward( sequence )

		# Calculate the emission table
		for k in xrange( n ):
			for i in xrange( self.silent_start ):
				s = <State>self.states[i]
				d = <Distribution>(s.distribution)
				log_probability = d.log_probability( sequence[k] )
				e[k, i] = log_probability

		if self.finite == 1:
			log_sequence_probability = f[ n, self.end_index ]
		else:
			log_sequence_probability = NEGINF
			for i in xrange( self.silent_start ):
				log_sequence_probability = pair_lse( 
					log_sequence_probability, f[ i, self.end_index ] )
		
		# Is the sequence impossible? If so, don't bother calculating any more.
		if log_sequence_probability == NEGINF:
			print( "Warning: Sequence is impossible." )
			return ( None, None )

		for k in xrange( m ):
			# For each state we could have come from
			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				if li >= self.silent_start:
					continue

				# For each state we could go to (and emit a character)
				# Sum up probabilities that we later normalize by 
				# probability of sequence.
				log_transition_emission_probability_sum = NEGINF

				for i in xrange( n ):
					# For each character in the sequence
					# Add probability that we start and get up to state k, 
					# and go k->l, and emit the symbol from l, and go from l
					# to the end.
					log_transition_emission_probability_sum = pair_lse( 
						log_transition_emission_probability_sum, 
						f[i, k] + self.out_transition_log_probabilities[l] +
						e[i, li] + b[i+1, li] )

				# Now divide by probability of the sequence to make it given
				# this sequence, and add as this sequence's contribution to 
				# the expected transitions matrix's k, l entry.
				expected_transitions[k, li] += cexp(
					log_transition_emission_probability_sum - 
					log_sequence_probability )

			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				if li < self.silent_start:
					continue

				# For each silent state we can go to on the same character
				# Sum up probabilities that we later normalize by 
				# probability of sequence.

				log_transition_emission_probability_sum = NEGINF
				for i in xrange( n+1 ):
					# For each row in the forward DP table (where we can
					# have transitions to silent states) of which we have 1 
					# more than we have symbols...
						
					# Add probability that we start and get up to state k, 
					# and go k->l, and go from l to the end. In this case, 
					# we use forward and backward entries from the same DP 
					# table row, since no character is being emitted.
					log_transition_emission_probability_sum = pair_lse( 
						log_transition_emission_probability_sum, 
						f[i, k] + self.out_transition_log_probabilities[l]
						+ b[i, li] )
					
				# Now divide by probability of the sequence to make it given
				# this sequence, and add as this sequence's contribution to 
				# the expected transitions matrix's k, l entry.
				expected_transitions[k, li] += cexp(
					log_transition_emission_probability_sum -
					log_sequence_probability )
				
			if k < self.silent_start:
				# Now think about emission probabilities from this state
						  
				for i in xrange( n ):
					# For each symbol that came out
		   
					# What's the weight of this symbol for that state?
					# Probability that we emit index characters and then 
					# transition to state l, and that from state l we  
					# continue on to emit len(sequence) - (index + 1) 
					# characters, divided by the probability of the 
					# sequence under the model.
					# According to http://www1.icsi.berkeley.edu/Speech/
					# docs/HTKBook/node7_mn.html, we really should divide by
					# sequence probability.

					emission_weights[i,k] = f[i+1, k] + b[i+1, k] - \
						log_sequence_probability
		
		cdef int [:] visited
		cdef double tied_state_log_probability
		if tie == 1:
			visited = numpy.zeros( self.silent_start, dtype=numpy.int32 )

			for k in xrange( self.silent_start ):
				# Check to see if we have visited this a state within the set of
				# tied states this state belongs yet. If not, this is the first
				# state and we can calculate the tied probabilities here.
				if visited[k] == 1:
					continue
				visited[k] = 1

				# Set that we have visited all of the other members of this set
				# of tied states.
				for l in xrange( tied_states[k], tied_states[k+1] ):
					li = self.tied[l]
					visited[li] = 1

				for i in xrange( n ):
					# Begin the probability sum with the log probability of 
					# being in the current state.
					tied_state_log_probability = emission_weights[i, k]

					# Go through all the states this state is tied with, and
					# add up the probability of being in any of them, and
					# updated the visited list.
					for l in xrange( tied_states[k], tied_states[k+1] ):
						li = self.tied[l]
						tied_state_log_probability = pair_lse( 
							tied_state_log_probability, emission_weights[i, li] )

					# Now update them with the retrieved value
					for l in xrange( tied_states[k], tied_states[k+1] ):
						li = self.tied[l]
						emission_weights[i, li] = tied_state_log_probability

					# Update the initial state we started with
					emission_weights[i, k] = tied_state_log_probability

		return numpy.array( expected_transitions ), \
			numpy.array( emission_weights )

	def log_probability( self, sequence, path=None ):
		'''
		Calculate the log probability of a sequence, or alternatively a list of
		sequences, depending on what is passed in. If sequence is a single 
		sequence, it will return the probability of that sequence. If sequence
		is a list of sequences, then it will return the sum of all sequences.
		'''

		# Determine if the first element of sequence is an iterable. If not,
		# then a single sequence was passed in. Return the probability of
		# that sequence. Otherwise, a list of sequences was passed in.
		if not hasattr( sequence[0], '__iter__' ):
			# Calculate the log probability of the sequence. If a path is
			# provided, use that path. Otherwise, calculate the sum-of-all-path
			# probability.
			if not path:
				return self._log_probability( numpy.array( sequence ) )
			else:
				return self._log_probability_of_path( 
					numpy.array( sequence ), numpy.array( path ) )

		# Since a list of sequences was passed in, rename for better clarity
		# as to what is going on.
		sequences = sequence 

		# Start off with the sum being negative infinite, and calculate the
		# log sum exp of all the sequences.
		log_probability_sum = NEGINF

		# Go through all of the sequences, and calculate the probability of
		# all of the sequences.
		for i, sequence in enumerate( sequences ):
			# Calculate the log probability of the sequence. If a path is
			# provided, use that path. Otherwise, calculate the sum-of-all-path
			# probability.
			if not path:
				log_probability = self._log_probability( 
					numpy.array( sequence ) )
			else:
				log_probability = self._log_probability_of_path(
					numpy.array( sequence ), numpy.array( path[i] ) )

			# Use log sum exp to add it to the running sum.
			log_probability_sum = pair_lse( 
				log_probability_sum, log_probability )

		return log_probability_sum

	cdef double _log_probability( self, numpy.ndarray sequence ):
		'''
		Calculate the probability here, in a cython optimized function.
		'''

		cdef int i
		cdef double log_probability_sum
		cdef double [:,:] f 

		f = self.forward( sequence )
		if self.finite == 1:
			log_probability_sum = f[ len(sequence), self.end_index ]
		else:
			log_probability_sum = NEGINF
			for i in xrange( self.silent_start ):
				log_probability_sum = pair_lse( 
					log_probability_sum, f[ len(sequence), i] )

		return log_probability_sum

	cdef double _log_probability_of_path( self, numpy.ndarray sequence,
		State [:] path ):
		'''
		Calculate the probability of a sequence, given the path it took through
		the model.
		'''

		cdef int i=0, idx, j, ji, l, li, ki, m=len(self.states)
		cdef int p=len(path), n=len(sequence)
		cdef dict indices = { self.states[i]: i for i in xrange( m ) }
		cdef State state

		cdef int [:] out_edges = self.out_edge_count

		cdef double log_score = 0

		# Iterate over the states in the path, as the path needs to be either
		# equal in length or longer than the sequence, depending on if there
		# are silent states or not.
		for j in xrange( 1, p ):
			# Add the transition probability first, because both silent and
			# character generating states have to do the transition. So find
			# the index of the last state, and see if there are any out
			# edges from that state to the current state. This operation
			# requires time proportional to the number of edges leaving the
			# state, due to the way the sparse representation is set up.
			ki = indices[ path[j-1] ]
			ji = indices[ path[j] ]

			for l in xrange( out_edges[ki], out_edges[ki+1] ):
				li = self.out_transitions[l]
				if li == ji:
					log_score += self.out_transition_log_probabilities[l]
					break
				if l == out_edges[ki+1]-1:
					return NEGINF

			# If the state is not silent, then add the log probability of
			# emitting that observation from this state.
			if not path[j].is_silent():
				log_score += path[j].distribution.log_probability( 
					sequence[i] )
				i += 1

		return log_score

	def viterbi( self, sequence ):
		'''
		Run the Viterbi algorithm on the sequence given the model. This finds
		the ML path of hidden states given the sequence. Returns a tuple of the
		log probability of the ML path, or (-inf, None) if the sequence is
		impossible under the model. If a path is returned, it is a list of
		tuples of the form (sequence index, state object).

		This is fundamentally the same as the forward algorithm using max
		instead of sum, except the traceback is more complicated, because
		silent states in the current step can trace back to other silent states
		in the current step as well as states in the previous step.

		input
			sequence: a list (or numpy array) of observations

		output
			A tuple of the log probabiliy of the ML path, and the sequence of
			hidden states that comprise the ML path.

		See also: 
			- Viterbi implementation described well in the wikipedia article
			http://en.wikipedia.org/wiki/Viterbi_algorithm
		'''

		return self._viterbi( numpy.array( sequence ) )

	cdef tuple _viterbi(self, numpy.ndarray sequence):
		"""		
		This fills in self.v, the Viterbi algorithm DP table.
		
		This is fundamentally the same as the forward algorithm using max
		instead of sum, except the traceback is more complicated, because silent
		states in the current step can trace back to other silent states in the
		current step as well as states in the previous step.
		"""
		cdef unsigned int I_SIZE = sizeof( int ), D_SIZE = sizeof( double )

		cdef unsigned int n = sequence.shape[0], m = len(self.states)
		cdef double p
		cdef int i, l, k, ki
		cdef int [:,:] tracebackx, tracebacky
		cdef double [:,:] v, e
		cdef double state_log_probability
		cdef Distribution d
		cdef State s
		cdef int[:] in_edges = self.in_edge_count

		# Initialize the DP table. Each entry i, k holds the log probability of
		# emitting i symbols and ending in state k, starting from the start
		# state, along the most likely path.
		v = cvarray( shape=(n+1,m), itemsize=D_SIZE, format='d' )

		# Initialize the emission table, which contains the probability of
		# each entry i, k holds the probability of symbol i being emitted
		# by state k 
		e = cvarray( shape=(n,self.silent_start), itemsize=D_SIZE, format='d' )

		# Initialize two traceback matricies. Each entry in tracebackx points
		# to the x index on the v matrix of the next entry. Same for the
		# tracebacky matrix.
		tracebackx = cvarray( shape=(n+1,m), itemsize=I_SIZE, format='i' )
		tracebacky = cvarray( shape=(n+1,m), itemsize=I_SIZE, format='i' )

		for k in xrange( n ):
			for i in xrange( self.silent_start ):
				s = <State>self.states[i]
				d = <Distribution>(s.distribution)
				p = d.log_probability( sequence[k] ) + self.state_weights[i]
				e[k, i] = p

		# We catch when we trace back to (0, self.start_index), so we don't need
		# a traceback there.
		for i in xrange( m ):
			v[0, i] = NEGINF
		v[0, self.start_index] = 0
		# We must start in the start state, having emitted 0 symbols

		for l in xrange( self.silent_start, m ):
			# Handle transitions between silent states before the first symbol
			# is emitted. No non-silent states have non-zero probability yet, so
			# we can ignore them.
			if l == self.start_index:
				# Start state log-probability is already right. Don't touch it.
				continue

			for k in xrange( in_edges[l], in_edges[l+1] ):
				ki = self.in_transitions[k]
				if ki < self.silent_start or ki >= l:
					continue

				# For each current-step preceeding silent state k
				# This holds the log-probability coming that way
				state_log_probability = v[0, ki] + \
					self.in_transition_log_probabilities[k]

				if state_log_probability > v[0, l]:
					# New winner!
					v[0, l] = state_log_probability
					tracebackx[0, l] = 0
					tracebacky[0, l] = ki

		for i in xrange( n ):
			for l in xrange( self.silent_start ):
				# Do the recurrence for non-silent states l
				# Start out saying the best likelihood we have is -inf
				v[i+1, l] = NEGINF
				
				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]

					# For each previous state k
					# This holds the log-probability coming that way
					state_log_probability = v[i, ki] + \
						self.in_transition_log_probabilities[k] + e[i, l]

					if state_log_probability > v[i+1, l]:
						# Best to come from there to here
						v[i+1, l] = state_log_probability
						tracebackx[i+1, l] = i
						tracebacky[i+1, l] = ki

			for l in xrange( self.silent_start, m ):
				# Now do the first pass over the silent states, finding the best
				# current-step non-silent state they could come from.
				# Start out saying the best likelihood we have is -inf
				v[i+1, l] = NEGINF

				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]
					if ki >= self.silent_start:
						continue

					# For each current-step non-silent state k
					# This holds the log-probability coming that way
					state_log_probability = v[i+1, ki] + \
						self.in_transition_log_probabilities[k]

					if state_log_probability > v[i+1, l]:
						# Best to come from there to here
						v[i+1, l] = state_log_probability
						tracebackx[i+1, l] = i+1
						tracebacky[i+1, l] = ki

			for l in xrange( self.silent_start, m ):
				# Now the second pass through silent states, where we check the
				# silent states that could potentially reach here and see if
				# they're better than the non-silent states we found.

				for k in xrange( in_edges[l], in_edges[l+1] ):
					ki = self.in_transitions[k]
					if ki < self.silent_start or ki >= l:
						continue

					# For each current-step preceeding silent state k
					# This holds the log-probability coming that way
					state_log_probability = v[i+1, ki] + \
						self.in_transition_log_probabilities[k]

					if state_log_probability > v[i+1, l]:
						# Best to come from there to here
						v[i+1, l] = state_log_probability
						tracebackx[i+1, l] = i+1
						tracebacky[i+1, l] = ki

		# Now the DP table is filled in. If this is a finite model, get the
		# log likelihood of ending up in the end state after following the
		# ML path through the model. If an infinite sequence, find the state
		# which the ML path ends in, and begin there.
		cdef int end_index
		cdef double log_likelihood

		if self.finite == 1:
			log_likelihood = v[n, self.end_index]
			end_index = self.end_index
		else:
			end_index = numpy.argmax( v[n] )
			log_likelihood = v[n, end_index ]

		if log_likelihood == NEGINF:
			# The path is impossible, so don't even try a traceback. 
			return ( log_likelihood, None )

		# Otherwise, do the traceback
		# This holds the path, which we construct in reverse order
		cdef list path = []
		cdef int px = n, py = end_index, npx

		# This holds our current position (character, state) AKA (i, k).
		# We start at the end state
		while px != 0 or py != self.start_index:
			# Until we've traced back to the start...
			# Put the position in the path, making sure to look up the state
			# object to use instead of the state index.
			path.append( ( px, self.states[py] ) )

			# Go backwards
			npx = tracebackx[px, py]
			py = tracebacky[px, py]
			px = npx

		# We've now reached the start (if we didn't raise an exception because
		# we messed up the traceback)
		# Record that we start at the start
		path.append( (px, self.states[py] ) )

		# Flip the path the right way around
		path.reverse()

		# Return the log-likelihood and the right-way-arounded path
		return ( log_likelihood, path )

	def maximum_a_posteriori( self, sequence ):
		"""
		MAP decoding is an alternative to viterbi decoding, which returns the
		most likely state for each observation, based on the forward-backward
		algorithm. This is also called posterior decoding. This method is
		described on p. 14 of http://ai.stanford.edu/~serafim/CS262_2007/
		notes/lecture5.pdf

		WARNING: This may produce impossible sequences.
		"""

		return self._maximum_a_posteriori( numpy.array( sequence ) )

	
	cdef tuple _maximum_a_posteriori( self, numpy.ndarray sequence ):
		"""
		Actually perform the math here. Instead of calling forward-backward
		to get the emission weights, it's calculated here so that time isn't
		wasted calculating the transition counts. 
		"""

		cdef int i, k, l, li
		cdef int m=len(self.states), n=len(sequence)
		cdef double [:,:] f, b
		cdef double [:,:] emission_weights = numpy.zeros((n, self.silent_start))
		cdef int [:] tied_states = self.tied_state_count

		cdef double log_sequence_probability


		# Fill in both the F and B DP matrices.
		f = self.forward( sequence )
		b = self.backward( sequence )

		# Find out the probability of the sequence
		if self.finite == 1:
			log_sequence_probability = f[ n, self.end_index ]
		else:
			log_sequence_probability = NEGINF
			for i in xrange( self.silent_start ):
				log_sequence_probability = pair_lse( 
					log_sequence_probability, f[ i, self.end_index ] )
		
		# Is the sequence impossible? If so, don't bother calculating any more.
		if log_sequence_probability == NEGINF:
			print( "Warning: Sequence is impossible." )
			return ( None, None )

		for k in xrange( m ):				
			if k < self.silent_start:				  
				for i in xrange( n ):
					# For each symbol that came out
					# What's the weight of this symbol for that state?
					# Probability that we emit index characters and then 
					# transition to state l, and that from state l we  
					# continue on to emit len(sequence) - (index + 1) 
					# characters, divided by the probability of the 
					# sequence under the model.
					# According to http://www1.icsi.berkeley.edu/Speech/
					# docs/HTKBook/node7_mn.html, we really should divide by
					# sequence probability.
					emission_weights[i,k] = f[i+1, k] + b[i+1, k] - \
						log_sequence_probability
		
		cdef int [:] visited
		cdef double tied_state_log_probability
		visited = numpy.zeros( self.silent_start, dtype=numpy.int32 )

		for k in xrange( self.silent_start ):
			# Check to see if we have visited this a state within the set of
			# tied states this state belongs yet. If not, this is the first
			# state and we can calculate the tied probabilities here.
			if visited[k] == 1:
				continue
			visited[k] = 1

			# Set that we have visited all of the other members of this set
			# of tied states.
			for l in xrange( tied_states[k], tied_states[k+1] ):
				li = self.tied[l]
				visited[li] = 1

			for i in xrange( n ):
				# Begin the probability sum with the log probability of 
				# being in the current state.
				tied_state_log_probability = emission_weights[i, k]

				# Go through all the states this state is tied with, and
				# add up the probability of being in any of them, and
				# updated the visited list.
				for l in xrange( tied_states[k], tied_states[k+1] ):
					li = self.tied[l]
					tied_state_log_probability = pair_lse( 
						tied_state_log_probability, emission_weights[i, li] )

				# Now update them with the retrieved value
				for l in xrange( tied_states[k], tied_states[k+1] ):
					li = self.tied[l]
					emission_weights[i, li] = tied_state_log_probability

				# Update the initial state we started with
				emission_weights[i, k] = tied_state_log_probability

		cdef list path = [ ( self.start_index, self.start ) ]
		cdef double maximum_emission_weight
		cdef int maximum_index

		for k in xrange( n ):
			maximum_index = -1
			maximum_emission_weight = NEGINF

			for l in xrange( self.silent_start ):
				if emission_weights[k, l] > maximum_emission_weight:
					maximum_emission_weight = emission_weights[k, l]
					maximum_index = l

			path.append( ( maximum_index, self.states[maximum_index] ) )

		path.append( ( self.end_index, self.end ) )

		return 0, path

	def write(self, stream):
		"""
		Write out the HMM to the given stream in a format more sane than pickle.
		
		HMM must have been baked.
		
		HMM is written as a series of "<name> <Distribution>" pairs, which can
		be directly evaluated by the eval method. This makes them both human
		readable, and keeps the code for it super simple.
		
		The start state is the one named "<hmm name>-start" and the end state is
		the one named "<hmm name>-end". Start and end states are always silent.
		
		Having the number of states on the first line makes the format harder 
		for humans to write, but saves us from having to write a real 
		backtracking parser.
		"""
		
		# Change our name to remove all whitespace, as this causes issues
		# with the parsing later on.
		self.name = self.name.replace( " ", "_" )

		# Write our name.
		stream.write("{} {}\n".format(self.name, len(self.states)))
		
		for state in sorted(self.states, key=lambda s: s.name):
			# Write each state in order by name
			state.write(stream)
			
		# Get transitions.
		# Each is a tuple (from index, to index, log probability)
		transitions = []
		
		for k in xrange( len(self.states) ):
			for l in xrange( self.out_edge_count[k], self.out_edge_count[k+1] ):
				li = self.out_transitions[l]
				log_probability = self.out_transition_log_probabilities[l] 

				transitions.append( (k, li, log_probability) )
			
		for (from_index, to_index, log_probability) in transitions:
			
			# Write each transition, using state names instead of indices.
			# This requires lookups and makes state names need to be unique, but
			# it's more human-readable and human-writeable.
			
			# Get the name of the state we're leaving
			from_name = self.states[from_index].name.replace( " ", "_" )
			from_id = self.states[from_index].identity
			
			# And the one we're going to
			to_name = self.states[to_index].name.replace( " ", "_" )
			to_id = self.states[to_index].identity

			# And the probability
			probability = exp(log_probability)
			
			# Write it out
			stream.write("{} {} {} {} {}\n".format(
				from_name, to_name, probability, from_id, to_id ) )
			
	@classmethod
	def read(cls, stream, verbose=False):
		"""
		Read a HMM from the given stream, in the format used by write(). The 
		stream must end at the end of the data defining the HMM.
		"""
		
		# Read the name and state count (first line)
		header = stream.readline()
		
		if header == "":
			raise EOFError("EOF reading HMM header")
		
		# Spilt out the parts of the headr
		parts = header.strip().split()
		
		# Get the HMM name
		name = parts[0]
		
		# Get the number of states to read
		num_states = int(parts[-1])
		
		# Read and make the states.
		# Keep a dict of states by id
		states = {}
		
		for i in xrange(num_states):
			# Read in a state
			state = State.read(stream)
			
			# Store it in the state dict
			states[state.identity] = state

			# We need to find the start and end states before we can make the HMM.
			# Luckily, we know their names.
			if state.name == "{}-start".format( name ):
				start_state = state
			if state.name == "{}-end".format( name ):
				end_state = state
			
		# Make the HMM object to populate
		hmm = cls(name=name, start=start_state, end=end_state)
		
		for state in states.itervalues():
			if state != start_state and state != end_state:
				# This state isn't already in the HMM, so add it.
				hmm.add_state(state)

		# Now do the transitions (all the rest of the lines)
		for line in stream:
			# Pull out the from state name, to state name, and probability 
			# string
			(from_name, to_name, probability_string, from_id, to_id) = \
				line.strip().split()
			
			# Make the probability as a float
			probability = float(probability_string)
			
			# Look up the states and add the transition
			hmm.add_transition(states[from_id], states[to_id], probability)

		# Now our HMM is done.
		# Bake and return it.
		hmm.bake( merge=None )
		return hmm
	
	@classmethod
	def from_matrix( cls, transition_probabilities, distributions, starts, ends,
		state_names=None, name=None ):
		"""
		Take in a 2D matrix of floats of size n by n, which are the transition
		probabilities to go from any state to any other state. May also take in
		a list of length n representing the names of these nodes, and a model
		name. Must provide the matrix, and a list of size n representing the
		distribution you wish to use for that state, a list of size n indicating
		the probability of starting in a state, and a list of size n indicating
		the probability of ending in a state.

		For example, if you wanted a model with two states, A and B, and a 0.5
		probability of switching to the other state, 0.4 probability of staying
		in the same state, and 0.1 probability of ending, you'd write the HMM
		like this:

		matrix = [ [ 0.4, 0.5 ], [ 0.4, 0.5 ] ]
		distributions = [NormalDistribution(1, .5), NormalDistribution(5, 2)]
		starts = [ 1., 0. ]
		ends = [ .1., .1 ]
		state_names= [ "A", "B" ]

		model = Model.from_matrix( matrix, distributions, starts, ends, 
			state_names, name="test_model" )
		"""

		# Build the initial model
		model = Model( name=name )

		# Build state objects for every state with the appropriate distribution
		states = [ State( distribution, name=name ) for name, distribution in
			it.izip( state_names, distributions) ]

		n = len( states )

		# Add all the states to the model
		for state in states:
			model.add_state( state )

		# Connect the start of the model to the appropriate state
		for i, prob in enumerate( starts ):
			if prob != 0:
				model.add_transition( model.start, states[i], prob )

		# Connect all states to each other if they have a non-zero probability
		for i in xrange( n ):
			for j, prob in enumerate( transition_probabilities[i] ):
				if prob != 0.:
					model.add_transition( states[i], states[j], prob )

		# Connect states to the end of the model if a non-zero probability 
		for i, prob in enumerate( ends ):
			if prob != 0:
				model.add_transition( states[j], model.end, prob )

		model.bake()
		return model

	def train( self, sequences, stop_threshold=1E-9, min_iterations=0,
		max_iterations=None, algorithm='baum-welch', verbose=True,
		transition_pseudocount=0, use_pseudocount=False, edge_inertia=0, 
		emitted_probability_threshold=0 ):
		"""
		Given a list of sequences, performs re-estimation on the model
		parameters. The two supported algorithms are "baum-welch" and
		"viterbi," indicating their respective algorithm. Neither algorithm
		makes use of inertia, meaning that the previous graph model is
		thrown out and replaced with the one generated from the training
		algorithm.

		Baum-Welch: Iterates until the log of the "score" (total likelihood of 
		all sequences) changes by less than stop_threshold. Returns the final 
		log score.
	
		
		Always trains for at least min_iterations.

		Viterbi: Training performed by running each sequence through the
		viterbi decoding algorithm. Edge weight re-estimation is done by 
		recording the number of times a hidden state transitions to another 
		hidden state, and using the percentage of time that edge was taken.
		Emission re-estimation is done by retraining the distribution on
		every sample tagged as belonging to that state.

		Baum-Welch training is usually the more accurate method, but takes
		significantly longer. Viterbi is a good for situations in which
		accuracy can be sacrificed for time.
		"""

		# Convert the boolean into an integer for downstream use.
		use_pseudocount = int( use_pseudocount )

		if algorithm.lower() == 'labelled' or algorithm.lower() == 'labeled':
			for i, sequence in enumerate(sequences):
				sequences[i] = ( numpy.array( sequence[0] ), sequence[1] )

			# If calling the labelled training algorithm, then sequences is a
			# list of tuples of sequence, path pairs, not a list of sequences.
			# In order to get a good estimate, need to use the 
			log_probability_sum = self.log_probability( 
				[ seq for seq, path in sequences],
				[ path for seq, path in sequences ] )	
							
			self._train_labelled( sequences, transition_pseudocount, 
				use_pseudocount, edge_inertia )
		else:
			log_probability_sum = self.log_probability( sequences )

		# Cast everything as a numpy array for input into the other possible
		# training algorithms.
		sequences = numpy.array( sequences )
		for i, sequence in enumerate( sequences ):
			sequences[i] = numpy.array( sequence )

		if algorithm.lower() == 'viterbi':
			self._train_viterbi( sequences, transition_pseudocount,
				use_pseudocount, edge_inertia )

		elif algorithm.lower() == 'baum-welch':
			self._train_baum_welch( sequences, stop_threshold,
				min_iterations, max_iterations, verbose, 
				transition_pseudocount, use_pseudocount, edge_inertia, 
				emitted_probability_threshold )

		# If using the labeled training algorithm, then calculate the new
		# probability sum across the path it chose, instead of the
		# sum-of-all-paths probability.
		if algorithm.lower() == 'labelled' or algorithm.lower() == 'labeled':
			trained_log_probability_sum = self.log_probability(
				[ seq for seq, path in sequences ],
				[ path for seq, path in sequences ] )
		else:
			trained_log_probability_sum = self.log_probability( sequences )

		# Calculate the difference between the two measurements.
		improvement = trained_log_probability_sum - log_probability_sum

		if verbose:
			print "Total Training Improvement: ", improvement
		return improvement

	def _train_baum_welch(self, sequences, stop_threshold, min_iterations, 
		max_iterations, verbose, transition_pseudocount, use_pseudocount,
		edge_inertia, emitted_probability_threshold ):
		"""
		Given a list of sequences, perform Baum-Welch iterative re-estimation on
		the model parameters.
		
		Iterates until the log of the "score" (total likelihood of all 
		sequences) changes by less than stop_threshold. Returns the final log
		score.
		
		Always trains for at least min_iterations.
		"""

		# How many iterations of training have we done (counting the first)
		iteration, improvement = 0, float("+inf")
		last_log_probability_sum = self.log_probability ( sequences )

		while improvement > stop_threshold or iteration < min_iterations:
			if max_iterations and iteration >= max_iterations:
				break 

			# Perform an iteration of Baum-Welch training.
			self._train_once_baum_welch( sequences, transition_pseudocount, 
				use_pseudocount, edge_inertia, emitted_probability_threshold )

			# Increase the iteration counter by one.
			iteration += 1

			# Calculate the improvement yielded by that iteration of
			# Baum-Welch.
			trained_log_probability_sum = self.log_probability( sequences )
			improvement = trained_log_probability_sum - last_log_probability_sum
			last_log_probability_sum = trained_log_probability_sum

			if verbose:
				print( "Training improvement: {}".format(improvement) )
			
	cdef void _train_once_baum_welch(self, numpy.ndarray sequences, 
		double transition_pseudocount, int use_pseudocount, double edge_inertia,
		double emitted_probability_threshold ):
		"""
		Implements one iteration of the Baum-Welch algorithm, as described in:
		http://www.cs.cmu.edu/~durand/03-711/2006/Lectures/hmm-bw.pdf
			
		Returns the log of the "score" under the *previous* set of parameters. 
		The score is the sum of the likelihoods of all the sequences.
		"""        

		cdef double [:,:] transition_log_probabilities 
		cdef double [:,:] expected_transitions, e, f, b
		cdef numpy.ndarray emitted_symbols
		cdef double [:,:] emission_weights
		cdef numpy.ndarray sequence
		cdef double log_sequence_probability, weight
		cdef double equence_probability_sum
		cdef int k, i, l, li, m = len( self.states ), n, observation=0
		cdef int characters_so_far = 0
		cdef object symbol

		cdef int [:] out_edges = self.out_edge_count
		cdef int [:] in_edges = self.in_edge_count

		# Find the expected number of transitions between each pair of states, 
		# given our data and our current parameters, but allowing the paths 
		# taken to vary. (Indexed: from, to)
		expected_transitions = numpy.zeros(( m, m ))

		# We also need to keep a list of all emitted symbols, and a list of 
		# weights for each state for each of those symbols.
		# This is the concatenated list of emitted symbols
		total_characters = 0
		for sequence in sequences:
			total_characters += len( sequence )

		emitted_symbols = numpy.zeros( total_characters, dtype=type(sequences[0][0]) )

		# This is a list lists of symbol weights, by state number, for 
		# non-silent states
		emission_weights = numpy.zeros(( self.silent_start, total_characters ))

		for sequence in sequences:
			n = len( sequence )
			# Calculate the emission table
			e = numpy.zeros(( n, self.silent_start )) 
			for k in xrange( n ):
				for i in xrange( self.silent_start ):
					e[k, i] = self.states[i].distribution.log_probability( 
						sequence[k] )

			# Get the overall log probability of the sequence, and fill in the
			# the forward DP matrix.
			f = self.forward( sequence )
			if self.finite == 1:
				log_sequence_probability = f[ n, self.end_index ]
			else:
				log_sequence_probability = NEGINF
				for i in xrange( self.silent_start ):
					log_sequence_probability = pair_lse( f[n, i],
						log_sequence_probability )

			# Is the sequence impossible? If so, we can't train on it, so skip 
			# it
			if log_sequence_probability == NEGINF:
				print( "Warning: skipped impossible sequence {}".format(sequence) )
				continue

			# Fill in the backward DP matrix.
			b = self.backward(sequence)

			# Save the sequence in the running list of all emitted symbols
			for i in xrange( n ):
				emitted_symbols[characters_so_far+i] = sequence[i]

			for k in xrange( m ):
				# For each state we could have come from
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li >= self.silent_start:
						continue

					# For each state we could go to (and emit a character)
					# Sum up probabilities that we later normalize by 
					# probability of sequence.
					log_transition_emission_probability_sum = NEGINF
					for i in xrange( n ):
						# For each character in the sequence
						# Add probability that we start and get up to state k, 
						# and go k->l, and emit the symbol from l, and go from l
						# to the end.
						log_transition_emission_probability_sum = pair_lse( 
							log_transition_emission_probability_sum, 
							f[i, k] + 
							self.out_transition_log_probabilities[l] + 
							e[i, li] + b[ i+1, li] )

					# Now divide by probability of the sequence to make it given
					# this sequence, and add as this sequence's contribution to 
					# the expected transitions matrix's k, l entry.
					expected_transitions[k, li] += cexp(
						log_transition_emission_probability_sum - 
						log_sequence_probability)

				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					if li < self.silent_start:
						continue
					# For each silent state we can go to on the same character
					# Sum up probabilities that we later normalize by 
					# probability of sequence.
					log_transition_emission_probability_sum = NEGINF
					for i in xrange( n + 1 ):
						# For each row in the forward DP table (where we can
						# have transitions to silent states) of which we have 1 
						# more than we have symbols...

						# Add probability that we start and get up to state k, 
						# and go k->l, and go from l to the end. In this case, 
						# we use forward and backward entries from the same DP 
						# table row, since no character is being emitted.
						log_transition_emission_probability_sum = pair_lse( 
							log_transition_emission_probability_sum, 
							f[i, k] + self.out_transition_log_probabilities[l] 
							+ b[i, li] )

					# Now divide by probability of the sequence to make it given
					# this sequence, and add as this sequence's contribution to 
					# the expected transitions matrix's k, l entry.
					expected_transitions[k, li] += cexp(
						log_transition_emission_probability_sum -
						log_sequence_probability )

				if k < self.silent_start:
					# Now think about emission probabilities from this state

					for i in xrange( n ):
						# For each symbol that came out

						# What's the weight of this symbol for that state?
						# Probability that we emit index characters and then 
						# transition to state l, and that from state l we  
						# continue on to emit len(sequence) - (index + 1) 
						# characters, divided by the probability of the 
						# sequence under the model.
						# According to http://www1.icsi.berkeley.edu/Speech/
						# docs/HTKBook/node7_mn.html, we really should divide by
						# sequence probability.
						weight = cexp(f[i+1, k] + b[i+1, k] - 
							log_sequence_probability)

						# Add this weight to the weight list for this state
						emission_weights[k, characters_so_far+i] = weight

			characters_so_far += n

		# We now have expected_transitions taking into account all sequences.
		# And a list of all emissions, and a weighting of each emission for each
		# state
		# Normalize transition expectations per row (so it becomes transition 
		# probabilities)
		# See http://stackoverflow.com/a/8904762/402891
		# Only modifies transitions for states a transition was observed from.
		cdef double [:] norm = numpy.zeros( m )
		cdef double probability

		# Calculate the regularizing norm for each node
		for k in xrange( m ):
			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				norm[k] += expected_transitions[k, li] + \
					transition_pseudocount + \
					self.out_transition_pseudocounts[l] * use_pseudocount

		# For every node, update the transitions appropriately
		for k in xrange( m ):
			# Recalculate each transition out from that node and update
			# the vector of out transitions appropriately
			if norm[k] > 0:
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					probability = ( expected_transitions[k, li] +
						transition_pseudocount + 
						self.out_transition_pseudocounts[l] * use_pseudocount)\
						/ norm[k]
					self.out_transition_log_probabilities[l] = clog(
						cexp( self.out_transition_log_probabilities[l] ) * 
						edge_inertia + probability * ( 1 - edge_inertia ) )

			# Recalculate each transition in to that node and update the
			# vector of in transitions appropriately 
			for l in xrange( in_edges[k], in_edges[k+1] ):
				li = self.in_transitions[l]
				if norm[li] > 0:
					probability = ( expected_transitions[li, k] +
						transition_pseudocount +
						self.in_transition_pseudocounts[l] * use_pseudocount )\
						/ norm[li]
					self.in_transition_log_probabilities[l] = clog( 
						cexp( self.in_transition_log_probabilities[l] ) *
						edge_inertia + probability * ( 1 - edge_inertia ) )

		# Define several helped variables.
		cdef double tied_state_probability
		cdef int [:] visited = numpy.zeros( self.silent_start,
			dtype=numpy.int32 )
		cdef int [:] tied_states = self.tied_state_count
		cdef list symbols, weights

		for k in xrange(self.silent_start):
			# If this distribution has already been trained because it is tied
			# to an earlier state, don't bother retraining it as that would
			# waste time.
			if visited[k] == 1:
				continue
			visited[k] = 1

			# Re-estimate the emission distribution for every non-silent state.
			# Take each emission weighted by the probability that we were in 
			# this state when it came out, given that the model generated the 
			# sequence that the symbol was part of. Take into account tied
			# states by only training that distribution one time, since many
			# states are pointing to the same distribution object.
			symbols = []
			weights = []

			for i in xrange( total_characters ):
				# Start off by assuming the probability for this character is
				# the probability in the emitted_symbols list.
				tied_state_probability = emission_weights[k, i]

				# Go through and see if this symbol was emitted in any of the
				# other states, and indicate they have all been visited.
				for l in xrange( tied_states[k], tied_states[k+1] ):
					li = self.tied[l]
					tied_state_probability += emission_weights[li, i]
					visited[li] = 1

				# If the symbol was emitted by any of the states, then add it
				# to the list of symbols used to train the underlying
				# distribution.
				if tied_state_probability > emitted_probability_threshold:
					symbols.append( emitted_symbols[i] )
					weights.append( tied_state_probability )

			# Now train this distribution on the symbols collected. If there
			# are tied states, this will be done once per set of tied states
			# in order to save time.
			self.states[k].distribution.from_sample( symbols, 
				weights=weights )


	cdef void _train_viterbi( self, numpy.ndarray sequences, 
		double transition_pseudocount, int use_pseudocount, 
		double edge_inertia ):
		"""
		Performs a simple viterbi training algorithm. Each sequence is tagged
		using the viterbi algorithm, and both emissions and transitions are
		updated based on the probabilities in the observations.
		"""

		cdef numpy.ndarray sequence
		cdef list sequence_path_pairs = []

		for sequence in sequences:

			# Run the viterbi decoding on each observed sequence
			log_sequence_probability, sequence_path = self.viterbi( sequence )
			if log_sequence_probability == NEGINF:
				print( "Warning: skipped impossible sequence {}".format(sequence) )
				continue

			# Strip off the ID
			for i in xrange( len( sequence_path ) ):
				sequence_path[i] = sequence_path[i][1]

			sequence_path_pairs.append( (sequence, sequence_path) )

		self._train_labelled( sequence_path_pairs, 
			transition_pseudocount, use_pseudocount, edge_inertia )

	cdef void _train_labelled( self, list sequences,
		double transition_pseudocount, int use_pseudocount,
		double edge_inertia ):
		"""
		Perform training on a set of sequences where the state path is known,
		thus, labelled. Pass in a list of tuples, where each tuple is of the
		form (sequence, labels).
		"""

		cdef int i, j, m=len(self.states), n, a, b, k, l, li
		cdef int total_characters=0
		cdef numpy.ndarray sequence 
		cdef list labels
		cdef State label
		cdef list symbols = [ [] for i in xrange( self.silent_start ) ]
		cdef int [:] tied_states = self.tied_state_count

		# Get the total number of characters emitted by going through each
		# sequence and getting the length
		for sequence, labels in sequences:
			total_characters += len( sequence )

		# Define matrices for the transitions between states, and the weight of
		# each emission for each state for training later.
		cdef int [:,:] transition_counts
		transition_counts = numpy.zeros((m,m), dtype=numpy.int32)

		cdef int [:] in_edges = self.in_edge_count
		cdef int [:] out_edges = self.out_edge_count

		# Define a mapping of state objects to index 
		cdef dict indices = { self.states[i]: i for i in xrange( m ) }

		# Keep track of the log score across all sequences 
		for sequence, labels in sequences:
			n = len(sequence)

			# Keep track of the number of transitions from one state to another
			transition_counts[ self.start_index, indices[labels[0]] ] += 1
			for i in xrange( len(labels)-1 ):
				a = indices[labels[i]]
				b = indices[labels[i+1]]
				transition_counts[ a, b ] += 1
			transition_counts[ indices[labels[-1]], self.end_index ] += 1

			# Indicate whether or not an emission came from a state or not.
			i = 0
			for label in labels:
				if label.is_silent():
					continue
				
				# Add the symbol to the list of symbols emitted from a given
				# state.
				k = indices[label]
				symbols[k].append( sequence[i] )
				# Also add the symbol to the list of symbols emitted from any
				# tied states to the current state.
				for l in xrange( tied_states[k], tied_states[k+1] ):
					li = self.tied[l]
					symbols[li].append( sequence[i] )

				# Move to the next observation.
				i += 1

		cdef double [:] norm = numpy.zeros( m )
		cdef double probability

		# Calculate the regularizing norm for each node for normalizing the
		# transition probabilities.
		for k in xrange( m ):
			for l in xrange( out_edges[k], out_edges[k+1] ):
				li = self.out_transitions[l]
				norm[k] += transition_counts[k, li] + transition_pseudocount +\
					self.out_transition_pseudocounts[l] * use_pseudocount

		# For every node, update the transitions appropriately
		for k in xrange( m ):
			# Recalculate each transition out from that node and update
			# the vector of out transitions appropriately
			if norm[k] > 0:
				for l in xrange( out_edges[k], out_edges[k+1] ):
					li = self.out_transitions[l]
					probability = ( transition_counts[k, li] +
						transition_pseudocount + 
						self.out_transition_pseudocounts[l] * use_pseudocount)\
						/ norm[k]
					self.out_transition_log_probabilities[l] = clog(
						cexp( self.out_transition_log_probabilities[l] ) * 
						edge_inertia + probability * ( 1 - edge_inertia ) )

			# Recalculate each transition in to that node and update the
			# vector of in transitions appropriately 
			for l in xrange( in_edges[k], in_edges[k+1] ):
				li = self.in_transitions[l]
				if norm[li] > 0:
					probability = ( transition_counts[li, k] +
						transition_pseudocount +
						self.in_transition_pseudocounts[l] * use_pseudocount )\
						/ norm[li]
					self.in_transition_log_probabilities[l] = clog( 
						cexp( self.in_transition_log_probabilities[l] ) *
						edge_inertia + probability * ( 1 - edge_inertia ) )

		cdef int [:] visited = numpy.zeros( self.silent_start,
			dtype=numpy.int32 )

		for k in xrange(self.silent_start):
			# If this distribution has already been trained because it is tied
			# to an earlier state, don't bother retraining it as that would
			# waste time.
			if visited[k] == 1:
				continue
			visited[k] = 1

			# We only want to train each distribution object once, and so we
			# don't want to visit states where the distribution has already
			# been retrained.
			for l in xrange( tied_states[k], tied_states[k+1] ):
				li = self.tied[l]
				visited[li] = 1

			# Now train this distribution on the symbols collected. If there
			# are tied states, this will be done once per set of tied states
			# in order to save time.
			self.states[k].distribution.from_sample( symbols[k] )
